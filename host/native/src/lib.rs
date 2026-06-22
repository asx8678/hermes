use std::collections::HashMap;

#[rustler::nif(schedule = "DirtyCpu")]
fn count_tokens(text: String, _model: String) -> i64 {
    // Approximate token count using a simple heuristic:
    // ~4 chars per token for English text (matching Python's estimate_messages_tokens_rough)
    // CJK: ~1 char per token.
    // This is a rough estimate — exact tokenization requires the model's tokenizer.
    estimate_tokens(&text)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn estimate_messages_tokens(messages: Vec<HashMap<String, String>>) -> i64 {
    // Sum token estimates across all messages.
    // Port of Python's estimate_messages_tokens_rough.
    messages
        .iter()
        .map(|m| {
            let content = m.get("content").cloned().unwrap_or_default();
            estimate_tokens(&content)
        })
        .sum()
}

fn estimate_tokens(text: &str) -> i64 {
    let cjk_count = text.chars().filter(|c| is_cjk(*c)).count();
    let ascii_count = text.chars().filter(|c| !is_cjk(*c)).count();
    (cjk_count + (ascii_count / 4)) as i64
}

fn is_cjk(c: char) -> bool {
    matches!(
        c as u32,
        0x4E00..=0x9FFF   // CJK Unified Ideographs
        | 0x3400..=0x4DBF   // CJK Extension A
        | 0x20000..=0x2A6DF // CJK Extension B
        | 0x3040..=0x309F   // Hiragana
        | 0x30A0..=0x30FF   // Katakana
        | 0xAC00..=0xD7AF   // Hangul
    )
}

rustler::init!(
    "Elixir.Hermes.Native",
    [count_tokens, estimate_messages_tokens]
);
