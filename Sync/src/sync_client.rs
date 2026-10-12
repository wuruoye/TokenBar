use std::io::Read;
use std::time::Duration;

use reqwest::blocking::Client;
use reqwest::header::CONTENT_TYPE;
use reqwest::redirect::Policy;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use thiserror::Error;
use url::{Host, Url};
use uuid::Uuid;

use crate::protocol::{
    normalize_download, validate_upload_envelope, DownloadResponse, UploadEnvelope,
    MAX_UPLOAD_BYTES,
};
use crate::incremental::{V2UploadEnvelope, PROTOCOL_V2};
use crate::weekly_resets::ResetMetadataResponse;

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

    fn v2_upload_url(&self, device_id: Uuid) -> Url {
        let mut url = self.0.clone();
        url.set_path(&format!("/v2/snapshots/{device_id}"));
        url
    }
    fn query_url(&self) -> Url {
        let mut url = self.0.clone(); url.set_path("/v2/snapshots/query"); url
    }

    fn reset_metadata_url(&self) -> Url {
        let mut url = self.0.clone();
        url.set_path("/v2/reset-metadata");
        url
    }

    pub fn state_key(&self) -> String {
        self.0.as_str().to_string()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct UploadResult {
    pub http_status: u16,
}

#[derive(Debug, Clone, Copy)]
pub struct IncrementalUploadResult {
    pub http_status: u16,
    pub revision: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IncrementalUploadResponse {
    protocol_version: u32,
    revision: u64,
    status: String,
    received_at_ms: i64,
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
    #[error("server response is not valid protocol v2 JSON")]
    InvalidV2Response,
}

impl SyncError {
    pub fn category(&self) -> &'static str {
        match self {
            Self::InvalidEndpoint | Self::HttpsRequired | Self::MissingToken => "configuration",
            Self::UploadTooLarge | Self::ServerBodyTooLarge | Self::DownloadTooLarge => "size",
            Self::Encode | Self::InvalidDownload | Self::InvalidV2Response => "protocol",
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
            .no_proxy()
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

    pub fn upload_v2(
        &self,
        token: &str,
        envelope: &V2UploadEnvelope,
    ) -> Result<IncrementalUploadResult, SyncError> {
        require_token(token)?;
        let body = serde_json::to_vec(envelope).map_err(|_| SyncError::Encode)?;
        if body.len() > MAX_UPLOAD_BYTES {
            return Err(SyncError::UploadTooLarge);
        }
        let response = self
            .client
            .put(self.endpoint.v2_upload_url(envelope.device_id()))
            .bearer_auth(token)
            .header(CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .map_err(|_| SyncError::Network)?;
        let status = response.status().as_u16();
        match status {
            200..=299 => {}
            401 | 403 => return Err(SyncError::Authentication),
            409 => return Err(SyncError::Conflict),
            413 => return Err(SyncError::ServerBodyTooLarge),
            other => return Err(SyncError::Http(other)),
        }
        let decoded: IncrementalUploadResponse =
            decode_limited(response, 64 * 1024, SyncError::InvalidV2Response)?;
        if decoded.protocol_version != PROTOCOL_V2
            || decoded.revision == 0
            || decoded.received_at_ms <= 0
            || !matches!(decoded.status.as_str(), "created" | "updated" | "retry")
        {
            return Err(SyncError::InvalidV2Response);
        }
        Ok(IncrementalUploadResult {
            http_status: status,
            revision: decoded.revision,
        })
    }

    pub fn reset_metadata(&self, token: &str) -> Result<ResetMetadataResponse, SyncError> {
        require_token(token)?;
        let response = self
            .client
            .get(self.endpoint.reset_metadata_url())
            .bearer_auth(token)
            .send()
            .map_err(|_| SyncError::Network)?;
        let status = response.status().as_u16();
        match status {
            200..=299 => {}
            401 | 403 => return Err(SyncError::Authentication),
            other => return Err(SyncError::Http(other)),
        }
        let decoded: ResetMetadataResponse =
            decode_limited(response, 64 * 1024, SyncError::InvalidV2Response)?;
        if decoded.protocol_version != PROTOCOL_V2 {
            return Err(SyncError::InvalidV2Response);
        }
        Ok(decoded)
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

    pub fn query_v2(&self, token: &str, query: &crate::download::QueryRequest) -> Result<crate::download::QueryResponse, SyncError> {
        require_token(token)?;
        let body = serde_json::to_vec(query).map_err(|_| SyncError::Encode)?;
        if body.len() > MAX_UPLOAD_BYTES { return Err(SyncError::UploadTooLarge); }
        let response = self.client.post(self.endpoint.query_url()).bearer_auth(token)
            .header(CONTENT_TYPE, "application/json").body(body).send().map_err(|_| SyncError::Network)?;
        match response.status().as_u16() {
            200..=299 => decode_limited(response, MAX_DOWNLOAD_BYTES, SyncError::InvalidV2Response),
            401 | 403 => Err(SyncError::Authentication),
            other => Err(SyncError::Http(other)),
        }
    }
}

fn decode_limited<T: DeserializeOwned>(
    response: reqwest::blocking::Response,
    limit: usize,
    invalid: SyncError,
) -> Result<T, SyncError> {
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(SyncError::DownloadTooLarge);
    }
    let mut bytes = Vec::new();
    response
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| SyncError::Network)?;
    if bytes.len() > limit {
        return Err(SyncError::DownloadTooLarge);
    }
    serde_json::from_slice(&bytes).map_err(|_| invalid)
}

fn require_token(token: &str) -> Result<(), SyncError> {
    if token.trim().is_empty() {
        return Err(SyncError::MissingToken);
    }
    Ok(())
}
