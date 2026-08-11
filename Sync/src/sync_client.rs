use std::io::Read;
use std::time::Duration;

use reqwest::blocking::Client;
use reqwest::header::CONTENT_TYPE;
use reqwest::redirect::Policy;
use thiserror::Error;
use url::{Host, Url};
use uuid::Uuid;

use crate::protocol::{
    normalize_download, validate_upload_envelope, DownloadResponse, UploadEnvelope,
    MAX_UPLOAD_BYTES,
};

const MAX_DOWNLOAD_BYTES: usize = 64 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);

#[derive(Debug, Clone)]
pub struct Endpoint(Url);

impl Endpoint {
    pub fn parse(value: &str) -> Result<Self, SyncError> {
        Self::parse_with_policy(value, true)
    }

    fn parse_with_policy(value: &str, allow_http_loopback: bool) -> Result<Self, SyncError> {
        let url = Url::parse(value).map_err(|_| SyncError::InvalidEndpoint)?;
        let secure = url.scheme() == "https";
        let http_loopback = allow_http_loopback
            && url.scheme() == "http"
            && match url.host() {
                Some(Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
                Some(Host::Ipv4(address)) => address.is_loopback(),
                Some(Host::Ipv6(address)) => address.is_loopback(),
                None => false,
            };
        if !secure && !http_loopback {
            return Err(SyncError::HttpsRequired);
        }
        if !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !matches!(url.path(), "" | "/")
        {
            return Err(SyncError::InvalidEndpoint);
        }
        Ok(Self(url))
    }

    fn snapshots_url(&self) -> Url {
        let mut url = self.0.clone();
        url.set_path("/v1/snapshots");
        url
    }

    fn upload_url(&self, device_id: Uuid) -> Url {
        let mut url = self.0.clone();
        url.set_path(&format!("/v1/snapshots/{device_id}"));
        url
    }
}

#[derive(Debug, Clone, Copy)]
pub struct UploadResult {
    pub http_status: u16,
}

#[derive(Debug, Error)]
pub enum SyncError {
    #[error(
        "sync endpoint must be a valid origin URL without credentials, path, query, or fragment"
    )]
    InvalidEndpoint,
    #[error("non-loopback sync endpoints must use HTTPS")]
    HttpsRequired,
    #[error("TOKENBAR_SYNC_TOKEN is not configured")]
    MissingToken,
    #[error("serialized upload exceeds the 16 MiB protocol limit")]
    UploadTooLarge,
    #[error("could not encode the upload envelope")]
    Encode,
    #[error("network request failed")]
    Network,
    #[error("server rejected authentication")]
    Authentication,
    #[error("server rejected this older generatedAtMs with HTTP 409")]
    Conflict,
    #[error("server rejected the request body as too large")]
    ServerBodyTooLarge,
    #[error("server returned HTTP {0}")]
    Http(u16),
    #[error("download exceeds the 64 MiB client safety limit")]
    DownloadTooLarge,
    #[error("download response is not valid protocol v1 JSON")]
    InvalidDownload,
}

impl SyncError {
    pub fn category(&self) -> &'static str {
        match self {
            Self::InvalidEndpoint | Self::HttpsRequired | Self::MissingToken => "configuration",
            Self::UploadTooLarge | Self::ServerBodyTooLarge | Self::DownloadTooLarge => "size",
            Self::Encode | Self::InvalidDownload => "protocol",
            Self::Network => "network",
            Self::Authentication => "authentication",
            Self::Conflict => "conflict",
            Self::Http(_) => "http",
        }
    }

    pub fn http_status(&self) -> Option<u16> {
        match self {
            Self::Authentication => Some(401),
            Self::Conflict => Some(409),
            Self::ServerBodyTooLarge => Some(413),
            Self::Http(status) => Some(*status),
            _ => None,
        }
    }
}

pub struct SyncClient {
    client: Client,
    endpoint: Endpoint,
}

impl SyncClient {
    pub fn new(endpoint: Endpoint) -> Result<Self, SyncError> {
        let client = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(Policy::none())
            .user_agent(concat!("tokenbar-sync/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| SyncError::Network)?;
        Ok(Self { client, endpoint })
    }

    pub fn upload(
        &self,
        token: &str,
        envelope: &UploadEnvelope,
    ) -> Result<UploadResult, SyncError> {
        require_token(token)?;
        validate_upload_envelope(envelope).map_err(|_| SyncError::Encode)?;
        let body = serde_json::to_vec(envelope).map_err(|_| SyncError::Encode)?;
        if body.len() > MAX_UPLOAD_BYTES {
            return Err(SyncError::UploadTooLarge);
        }

        let response = self
            .client
            .put(self.endpoint.upload_url(envelope.device.id))
            .bearer_auth(token)
            .header(CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .map_err(|_| SyncError::Network)?;
        let status = response.status().as_u16();
        match status {
            200..=299 => Ok(UploadResult {
                http_status: status,
            }),
            401 | 403 => Err(SyncError::Authentication),
            409 => Err(SyncError::Conflict),
            413 => Err(SyncError::ServerBodyTooLarge),
            other => Err(SyncError::Http(other)),
        }
    }

    pub fn download(&self, token: &str) -> Result<DownloadResponse, SyncError> {
        require_token(token)?;
        let response = self
            .client
            .get(self.endpoint.snapshots_url())
            .bearer_auth(token)
            .send()
            .map_err(|_| SyncError::Network)?;
        let status = response.status().as_u16();
        match status {
            200..=299 => {}
            401 | 403 => return Err(SyncError::Authentication),
            other => return Err(SyncError::Http(other)),
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_DOWNLOAD_BYTES as u64)
        {
            return Err(SyncError::DownloadTooLarge);
        }

        let mut bytes = Vec::new();
        response
            .take((MAX_DOWNLOAD_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| SyncError::Network)?;
        if bytes.len() > MAX_DOWNLOAD_BYTES {
            return Err(SyncError::DownloadTooLarge);
        }
        let decoded: DownloadResponse =
            serde_json::from_slice(&bytes).map_err(|_| SyncError::InvalidDownload)?;
        normalize_download(decoded).map_err(|_| SyncError::InvalidDownload)
    }
}

fn require_token(token: &str) -> Result<(), SyncError> {
    if token.trim().is_empty() {
        return Err(SyncError::MissingToken);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;
    use std::time::Duration;

    use serde_json::json;
    use tokenbar_helper::SCHEMA_VERSION;

    use super::*;
    use crate::protocol::{DeviceDescriptor, DeviceOs, PROTOCOL_VERSION};

    fn serve_response(
        status: &'static str,
        response_body: &'static str,
        extra_headers: String,
    ) -> (String, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 4096];
            loop {
                let count = stream.read(&mut buffer).unwrap();
                if count == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..count]);
                if let Some(header_end) = request.windows(4).position(|value| value == b"\r\n\r\n")
                {
                    let headers = String::from_utf8_lossy(&request[..header_end + 4]);
                    let content_length = headers
                        .lines()
                        .find_map(|line| {
                            line.strip_prefix("content-length: ")
                                .or_else(|| line.strip_prefix("Content-Length: "))
                        })
                        .and_then(|value| value.parse::<usize>().ok())
                        .unwrap_or(0);
                    if request.len() >= header_end + 4 + content_length {
                        break;
                    }
                }
            }
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(response.as_bytes()).unwrap();
            String::from_utf8(request).unwrap()
        });
        (format!("http://{address}"), handle)
    }

    fn serve_once(response_body: &'static str) -> (String, thread::JoinHandle<String>) {
        serve_response("200 OK", response_body, String::new())
    }

    fn device(id: Uuid) -> DeviceDescriptor {
        DeviceDescriptor {
            id,
            name: "Windows test device".to_string(),
            os: DeviceOs::Windows,
            client_version: Some("test".to_string()),
        }
    }

    fn snapshot(generated_at_ms: i64) -> serde_json::Value {
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "generatedAtMs": generated_at_ms,
            "timezone": "UTC",
            "today": {},
            "sessions": [],
            "days": []
        })
    }

    #[test]
    fn non_loopback_endpoint_requires_https() {
        assert!(Endpoint::parse("http://127.0.0.1:18765").is_ok());
        assert!(Endpoint::parse("http://localhost:18765").is_ok());
        assert!(Endpoint::parse("http://[::1]:18765").is_ok());
        assert!(matches!(
            Endpoint::parse("http://192.0.2.1:18765"),
            Err(SyncError::HttpsRequired)
        ));
        assert!(Endpoint::parse("https://sync.example.test").is_ok());
        assert!(Endpoint::parse("https://user:pass@sync.example.test").is_err());
        assert!(Endpoint::parse("https://sync.example.test/prefix").is_err());
    }

    #[test]
    fn upload_uses_exact_v1_path_bearer_and_json_contract() {
        let (origin, server) = serve_once("{}");
        let endpoint = Endpoint::parse_with_policy(&origin, true).unwrap();
        let client = SyncClient::new(endpoint).unwrap();
        let id = Uuid::parse_str("ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF").unwrap();
        let envelope = UploadEnvelope {
            protocol_version: PROTOCOL_VERSION,
            device: device(id),
            generated_at_ms: 123,
            snapshot: snapshot(123),
        };

        let result = client.upload("test-only-placeholder", &envelope).unwrap();
        assert_eq!(result.http_status, 200);
        let request = server.join().unwrap();
        assert!(request.starts_with(&format!("PUT /v1/snapshots/{id} HTTP/1.1\r\n")));
        assert!(request
            .to_ascii_lowercase()
            .contains("authorization: bearer test-only-placeholder\r\n"));
        assert!(request
            .to_ascii_lowercase()
            .contains("content-type: application/json\r\n"));
        let body = request.split_once("\r\n\r\n").unwrap().1;
        let value: serde_json::Value = serde_json::from_str(body).unwrap();
        assert_eq!(value["protocolVersion"], 1);
        assert_eq!(value["device"]["id"], id.to_string());
        assert_eq!(value["device"]["os"], "windows");
        assert_eq!(value["generatedAtMs"], 123);
        assert!(value["snapshot"].is_object());
    }

    #[test]
    fn upload_rejects_more_than_sixteen_mib_before_network_io() {
        let endpoint = Endpoint::parse("https://sync.example.test").unwrap();
        let client = SyncClient::new(endpoint).unwrap();
        let mut large_snapshot = snapshot(123);
        large_snapshot
            .as_object_mut()
            .unwrap()
            .insert("padding".to_string(), json!("x".repeat(MAX_UPLOAD_BYTES)));
        let envelope = UploadEnvelope {
            protocol_version: PROTOCOL_VERSION,
            device: device(Uuid::new_v4()),
            generated_at_ms: 123,
            snapshot: large_snapshot,
        };

        assert!(matches!(
            client.upload("test-only-placeholder", &envelope),
            Err(SyncError::UploadTooLarge)
        ));
    }

    #[test]
    fn download_uses_get_and_resanitizes_server_rows() {
        let id = Uuid::new_v4();
        let body = format!(
            r#"{{"protocolVersion":1,"snapshots":[{{"device":{{"id":"{id}","name":"Windows test device","os":"windows"}},"generatedAtMs":123,"receivedAtMs":456,"snapshot":{{"schemaVersion":{SCHEMA_VERSION},"generatedAtMs":123,"timezone":"UTC","today":{{}},"sessions":[{{"title":"private","workspacePath":"C:\\private","workspaceLabel":"safe","requests":[{{"promptPreview":"private","outputPreview":"private","sessionPath":"C:\\private\\session.jsonl"}}]}}],"days":[]}}}}]}}"#
        );
        let leaked: &'static str = Box::leak(body.into_boxed_str());
        let (origin, server) = serve_once(leaked);
        let endpoint = Endpoint::parse_with_policy(&origin, true).unwrap();
        let client = SyncClient::new(endpoint).unwrap();
        let response = client.download("test-only-placeholder").unwrap();
        let request = server.join().unwrap();
        assert!(request.starts_with("GET /v1/snapshots HTTP/1.1\r\n"));
        let session = &response.snapshots[0].snapshot["sessions"][0];
        assert!(session["title"].is_null());
        assert!(session["workspacePath"].is_null());
        assert_eq!(session["workspaceLabel"], "safe");
        assert!(session["requests"][0]["promptPreview"].is_null());
        assert!(session["requests"][0]["outputPreview"].is_null());
        assert!(session["requests"][0]["sessionPath"].is_null());
    }

    #[test]
    fn redirects_are_rejected_before_bearer_can_reach_another_origin() {
        let leak_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let leak_address = leak_listener.local_addr().unwrap();
        leak_listener.set_nonblocking(true).unwrap();
        let leak_server = thread::spawn(move || {
            for _ in 0..50 {
                match leak_listener.accept() {
                    Ok((_stream, _)) => return true,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("leak listener failed: {error}"),
                }
            }
            false
        });
        let location = format!("Location: http://{leak_address}/v1/snapshots\r\n");
        let (origin, redirect_server) = serve_response("302 Found", "", location);
        let client = SyncClient::new(Endpoint::parse(&origin).unwrap()).unwrap();

        assert!(matches!(
            client.download("test-only-placeholder"),
            Err(SyncError::Http(302))
        ));
        redirect_server.join().unwrap();
        assert!(!leak_server.join().unwrap());
    }

    #[test]
    fn conflict_is_terminal_for_the_in_memory_upload() {
        let (origin, server) = serve_response("409 Conflict", "", String::new());
        let client = SyncClient::new(Endpoint::parse(&origin).unwrap()).unwrap();
        let envelope = UploadEnvelope {
            protocol_version: PROTOCOL_VERSION,
            device: device(Uuid::new_v4()),
            generated_at_ms: 123,
            snapshot: snapshot(123),
        };

        assert!(matches!(
            client.upload("test-only-placeholder", &envelope),
            Err(SyncError::Conflict)
        ));
        server.join().unwrap();
    }
}
