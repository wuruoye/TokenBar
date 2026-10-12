use serde_json::Value;

const SYSTEM_INJECTED_PREFIXES: &[&str] = &[
    "<environment_context>",
    "<system-reminder>",
    "<user_instructions>",
    "# AGENTS.md instructions",
    "<external_codex_apps_open_page>",
    "<recommended_plugins>",
    "<skill>",
];

pub(crate) fn human_message_text(mut text: &str) -> Option<&str> {
    loop {
        let trimmed = text.trim_start();
        if trimmed.starts_with("<in-app-browser-context ")
            || trimmed.starts_with("<in-app-browser-context>")
        {
            let (_, remainder) = trimmed.split_once("</in-app-browser-context>")?;
            let remainder = remainder.trim_start();
            text = remainder
                .strip_prefix("## My request:")
                .map(|request| request.trim_start_matches(['\r', '\n']))
                .unwrap_or(remainder);
            continue;
        }
        return (!trimmed.is_empty()
            && !SYSTEM_INJECTED_PREFIXES
                .iter()
                .any(|prefix| trimmed.starts_with(prefix)))
        .then_some(text);
    }
}

/// Extract text blocks before making a preview so injected blocks cannot hide
/// a user's request later in the same message.
pub(crate) fn message_content_text(content: &Value, role: &str) -> Option<String> {
    match content {
        Value::String(text) => {
            let text = if role == "user" {
                human_message_text(text)?
            } else {
                text.as_str()
            };
            (!text.trim().is_empty()).then(|| text.to_string())
        }
        Value::Array(blocks) => {
            let parts = blocks
                .iter()
                .filter_map(|block| message_content_text(block, role))
                .collect::<Vec<_>>();
            (!parts.is_empty()).then(|| parts.join("\n\n"))
        }
        Value::Object(block) => ["text", "content", "message", "input"]
            .iter()
            .find_map(|key| block.get(*key).and_then(|value| message_content_text(value, role))),
        _ => None,
    }
}
