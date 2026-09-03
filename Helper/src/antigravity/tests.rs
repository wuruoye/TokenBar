use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

fn temporary_home(name: &str) -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "tokenbar-antigravity-{name}-{}-{}",
        std::process::id(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(path.join(".gemini/antigravity/conversations")).unwrap();
    path
}

fn varint(value: u64) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut value = value;
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            bytes.push(byte);
            return bytes;
        }
        bytes.push(byte | 0x80);
    }
}

fn tag(number: u32, wire_type: u8) -> Vec<u8> {
    varint(u64::from(number) << 3 | u64::from(wire_type))
}

fn number_field(number: u32, value: i64) -> Vec<u8> {
    let mut bytes = tag(number, 0);
    bytes.extend(varint(value as u64));
    bytes
}

fn bytes_field(number: u32, value: &[u8]) -> Vec<u8> {
    let mut bytes = tag(number, 2);
    bytes.extend(varint(value.len() as u64));
    bytes.extend(value);
    bytes
}

fn text_field(number: u32, value: &str) -> Vec<u8> {
    bytes_field(number, value.as_bytes())
}

fn timestamp(number: u32, milliseconds: i64) -> Vec<u8> {
    let mut inner = number_field(1, milliseconds / 1_000);
    inner.extend(number_field(2, (milliseconds % 1_000) * 1_000_000));
    bytes_field(number, &inner)
}

fn concat(parts: &[Vec<u8>]) -> Vec<u8> {
    parts.concat()
}

/// Builds one `Usage` message with Antigravity's field numbering.
fn usage(model_key: i64, input: i64, cache_read: i64, reasoning: i64, text: i64) -> Vec<u8> {
    concat(&[
        number_field(USAGE_MODEL_KEY, model_key),
        number_field(USAGE_INPUT, input),
        number_field(USAGE_OUTPUT_TOTAL, reasoning + text),
        number_field(USAGE_CACHE_READ, cache_read),
        number_field(USAGE_REASONING, reasoning),
        number_field(USAGE_OUTPUT_TEXT, text),
    ])
}

struct StepFixture {
    step_type: i64,
    metadata: Vec<u8>,
    payload: Vec<u8>,
}

fn write_conversation(home: &Path, conversation_id: &str, steps: &[StepFixture]) -> PathBuf {
    let path = home
        .join(".gemini/antigravity/conversations")
        .join(format!("{conversation_id}.db"));
    let connection = Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0, \
             metadata blob, step_payload blob, PRIMARY KEY (idx));
             CREATE TABLE gen_metadata (idx integer, data blob, PRIMARY KEY (idx));
             CREATE TABLE trajectory_metadata_blob (id text DEFAULT \"main\", data blob, \
             PRIMARY KEY (id));",
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?1)",
            [text_field(7, "file:///Users/dev/Projects/tokenbar")],
        )
        .unwrap();
    for (index, step) in steps.iter().enumerate() {
        connection
            .execute(
                "INSERT INTO steps (idx, step_type, metadata, step_payload) \
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![
                    index as i64,
                    step.step_type,
                    step.metadata.clone(),
                    step.payload.clone()
                ],
            )
            .unwrap();
    }
    let generation = bytes_field(
        1,
        &concat(&[
            number_field(3, 1318),
            bytes_field(4, &usage(1318, 0, 0, 0, 0)),
            text_field(19, "gemini-3.8-flash"),
        ]),
    );
    connection
        .execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1)",
            [generation],
        )
        .unwrap();
    path
}

fn options(home: &Path) -> LocalParseOptions {
    LocalParseOptions {
        home_dir: Some(home.to_string_lossy().into_owned()),
        use_env_roots: false,
        since: None,
        until: None,
    }
}

fn sample_steps() -> Vec<StepFixture> {
    vec![
        StepFixture {
            step_type: STEP_TYPE_USER_MESSAGE,
            metadata: timestamp(META_STARTED_AT, 1_788_404_258_000),
            payload: bytes_field(
                PAYLOAD_USER_MESSAGE,
                &text_field(2, "Add Antigravity support"),
            ),
        },
        StepFixture {
            step_type: STEP_TYPE_CONVERSATION_START,
            metadata: concat(&[
                timestamp(META_STARTED_AT, 1_788_404_258_500),
                bytes_field(
                    META_TITLE_USAGE,
                    &bytes_field(2, &usage(0, 196, 0, 490, 6)),
                ),
            ]),
            payload: bytes_field(
                PAYLOAD_CONVERSATION_START,
                &concat(&[
                    text_field(4, "Antigravity Support"),
                    text_field(19, "Add Antigravity support"),
                ]),
            ),
        },
        StepFixture {
            step_type: STEP_TYPE_MODEL_RESPONSE,
            metadata: concat(&[
                timestamp(META_STARTED_AT, 1_788_404_260_000),
                timestamp(META_FIRST_TOKEN_AT, 1_788_404_261_000),
                timestamp(META_FINISHED_AT, 1_788_404_264_000),
                bytes_field(META_USAGE, &usage(1318, 29_632, 36_751, 568, 60)),
                number_field(META_MODEL_KEY, 1318),
            ]),
            payload: bytes_field(PAYLOAD_MODEL_RESPONSE, &text_field(8, "Done.")),
        },
    ]
}

#[test]
fn splits_generation_usage_into_disjoint_buckets() {
    let home = temporary_home("buckets");
    write_conversation(&home, "96d309be", &sample_steps());

    let messages = parse_local_antigravity_messages(
        options(&home),
        &AnthropicPricing::bundled_for_date(
            NaiveDate::from_ymd_opt(2026, 9, 3).unwrap(),
        ),
        &GooglePricing::bundled(),
    )
    .unwrap();

    let response = messages
        .iter()
        .find(|message| message.is_turn_start)
        .expect("the model response is reported");
    assert_eq!(response.model_id, "gemini-3.8-flash");
    assert_eq!(response.tokens.input, 29_632);
    assert_eq!(response.tokens.cache_read, 36_751);
    assert_eq!(response.tokens.reasoning, 568);
    assert_eq!(response.tokens.output, 60);
    assert_eq!(response.tokens.cache_write, 0);
    assert_eq!(response.tokens.total(), 67_011);
    assert_eq!(response.session_id, "96d309be");
    assert_eq!(
        response.workspace_key.as_deref(),
        Some("/Users/dev/Projects/tokenbar")
    );
    assert_eq!(response.model_duration_ms, Some(4_000));
    assert_eq!(response.time_to_first_token_ms, Some(1_000));
}

#[test]
fn starts_the_turn_on_the_model_response_instead_of_the_title_request() {
    let home = temporary_home("turn");
    write_conversation(&home, "96d309be", &sample_steps());

    let messages = parse_local_antigravity_messages(
        options(&home),
        &AnthropicPricing::bundled_for_date(
            NaiveDate::from_ymd_opt(2026, 9, 3).unwrap(),
        ),
        &GooglePricing::bundled(),
    )
    .unwrap();

    assert_eq!(messages.len(), 2);
    let starts = messages
        .iter()
        .filter(|message| message.is_turn_start)
        .collect::<Vec<_>>();
    assert_eq!(starts.len(), 1);
    assert_eq!(starts[0].model_id, "gemini-3.8-flash");
    assert_eq!(
        starts[0].content_preview.as_deref(),
        Some("Add Antigravity support")
    );
    assert_eq!(starts[0].output_preview.as_deref(), Some("Done."));
}

#[test]
fn prices_claude_and_gemini_models_from_their_own_catalogs() {
    let home = temporary_home("pricing");
    let mut steps = sample_steps();
    steps.push(StepFixture {
        step_type: STEP_TYPE_MODEL_RESPONSE,
        metadata: concat(&[
            timestamp(META_STARTED_AT, 1_788_404_270_000),
            timestamp(META_FINISHED_AT, 1_788_404_272_000),
            bytes_field(META_USAGE, &usage(4242, 1_000_000, 0, 0, 1_000_000)),
            number_field(META_MODEL_KEY, 4242),
        ]),
        payload: bytes_field(PAYLOAD_MODEL_RESPONSE, &text_field(8, "Reviewed.")),
    });
    let path = write_conversation(&home, "b4b35d8d", &steps);
    let connection = Connection::open(&path).unwrap();
    connection
        .execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (1, ?1)",
            [bytes_field(
                1,
                &concat(&[
                    number_field(3, 4242),
                    bytes_field(4, &usage(4242, 0, 0, 0, 0)),
                    text_field(19, "claude-opus-4-6-thinking"),
                ]),
            )],
        )
        .unwrap();
    drop(connection);

    let messages = parse_local_antigravity_messages(
        options(&home),
        &AnthropicPricing::bundled_for_date(
            NaiveDate::from_ymd_opt(2026, 9, 3).unwrap(),
        ),
        &GooglePricing::bundled(),
    )
    .unwrap();

    let claude = messages
        .iter()
        .find(|message| message.model_id == "claude-opus-4-6-thinking")
        .expect("the Claude request is reported");
    assert_eq!(claude.provider_id, "anthropic");
    assert_eq!(claude.cost_source, CostSource::Estimated);
    assert!((claude.cost - 30.0).abs() < 1e-9);

    let gemini = messages
        .iter()
        .find(|message| message.is_turn_start)
        .unwrap();
    assert_eq!(gemini.model_id, "gemini-3.8-flash");
    assert_eq!(gemini.provider_id, "google");
    assert_eq!(gemini.cost_source, CostSource::Estimated);
    // 29_632 input at $0.75/M, 36_751 cached at $0.075/M, and 628 output plus
    // thinking tokens at $3.75/M.
    let expected = 29_632.0 * 0.75 / 1_000_000.0
        + 36_751.0 * 0.075 / 1_000_000.0
        + 628.0 * 3.75 / 1_000_000.0;
    assert!((gemini.cost - expected).abs() < 1e-12);
}

#[test]
fn charges_gemini_pro_the_long_context_rate_above_two_hundred_thousand_tokens() {
    let pricing = GooglePricing::bundled();
    let short = pricing
        .calculate_token_costs(
            "gemini-2.5-pro",
            &TokenBreakdown {
                input: 200_000,
                output: 1_000,
                cache_read: 0,
                cache_write: 0,
                reasoning: 0,
            },
        )
        .unwrap();
    let long = pricing
        .calculate_token_costs(
            "gemini-2.5-pro",
            &TokenBreakdown {
                input: 200_001,
                output: 1_000,
                cache_read: 0,
                cache_write: 0,
                reasoning: 0,
            },
        )
        .unwrap();

    assert!((short.input - 0.25).abs() < 1e-12);
    assert!((long.input - 0.5000025).abs() < 1e-9);
    assert!((short.output - 0.01).abs() < 1e-12);
    assert!((long.output - 0.015).abs() < 1e-12);
    assert!(pricing
        .calculate_token_costs("gemini-9.9-flash", &TokenBreakdown::default())
        .is_none());
}

#[test]
fn falls_back_to_the_only_model_for_unattributed_summary_requests() {
    let home = temporary_home("summary");
    write_conversation(&home, "96d309be", &sample_steps());

    let messages = parse_local_antigravity_messages(
        options(&home),
        &AnthropicPricing::bundled_for_date(
            NaiveDate::from_ymd_opt(2026, 9, 3).unwrap(),
        ),
        &GooglePricing::bundled(),
    )
    .unwrap();

    let title = messages
        .iter()
        .find(|message| !message.is_turn_start)
        .expect("the title request is reported");
    assert_eq!(title.model_id, "gemini-3.8-flash");
    assert_eq!(title.tokens.input, 196);
    assert_eq!(title.tokens.reasoning, 490);
    assert_eq!(title.tokens.output, 6);
}

#[test]
fn reads_titles_and_request_detail() {
    let home = temporary_home("detail");
    let path = write_conversation(&home, "96d309be", &sample_steps());
    fs::write(
        home.join(".gemini/antigravity/agyhub_summaries_proto.pb"),
        bytes_field(
            1,
            &concat(&[
                text_field(1, "96d309be"),
                bytes_field(2, &text_field(1, "Antigravity Support")),
            ]),
        ),
    )
    .unwrap();

    let titles = load_antigravity_session_titles(&options(&home));
    assert_eq!(
        titles
            .get(&("antigravity".to_string(), "96d309be".to_string()))
            .map(String::as_str),
        Some("Antigravity Support")
    );

    let detail =
        extract_request_detail(&path, 1_788_404_263_000, 1_788_404_265_000).unwrap();
    assert_eq!(detail.prompt.as_deref(), Some("Add Antigravity support"));
    assert_eq!(detail.output.as_deref(), Some("Done."));
}
