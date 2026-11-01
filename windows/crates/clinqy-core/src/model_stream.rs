//! Bounded provider-neutral SSE decoding; chunks may split UTF-8, lines and event boundaries.
use anyhow::{bail, Result};
use serde_json::Value;

#[derive(Default)]
pub(crate) struct Stream {
    pending: Vec<u8>,
    data: Vec<String>,
    pub text: String,
    pub finished: bool,
    pub input: Option<u64>,
    pub output: Option<u64>,
    bytes: usize,
}
impl Stream {
    pub fn push(&mut self, bytes: &[u8]) -> Result<()> {
        self.bytes += bytes.len();
        if self.bytes > 4_000_000 {
            bail!("Model stream exceeded the response budget");
        }
        self.pending.extend_from_slice(bytes);
        let mut start = 0;
        for end in 0..self.pending.len() {
            if self.pending[end] == b'\n' {
                let line = std::str::from_utf8(&self.pending[start..end])?.trim_end_matches('\r').to_owned();
                start = end + 1;
                self.line(&line)?;
            }
        }
        if start > 0 {
            self.pending.drain(..start);
        }
        Ok(())
    }
    fn line(&mut self, line: &str) -> Result<()> {
        if line.is_empty() {
            return self.flush();
        }
        if let Some(data) = line.strip_prefix("data:") {
            self.data.push(data.trim_start().into());
        } else if line.starts_with('{') {
            self.event(line)?;
        }
        Ok(())
    }
    fn flush(&mut self) -> Result<()> {
        if !self.data.is_empty() {
            let data = self.data.join("\n");
            self.data.clear();
            self.event(&data)?;
        }
        Ok(())
    }
    pub fn finish(&mut self) -> Result<()> {
        if !self.pending.is_empty() {
            let last = String::from_utf8(std::mem::take(&mut self.pending))?;
            self.line(last.trim_end_matches('\r'))?;
        }
        self.flush()?;
        if !self.finished || self.text.is_empty() {
            bail!("Model stream ended before a complete answer");
        }
        Ok(())
    }
    fn event(&mut self, data: &str) -> Result<()> {
        if data == "[DONE]" {
            self.finished = true;
            return Ok(());
        }
        let v: Value = serde_json::from_str(data)?;
        if !v["error"].is_null() {
            bail!("Model stream error: {}", v["error"]);
        }
        if let Some(text) = v["choices"][0]["delta"]["content"].as_str() {
            self.text.push_str(text);
        }
        if !v["choices"][0]["finish_reason"].is_null() {
            self.finished = true;
        }
        if v["type"] == "content_block_delta" {
            if let Some(text) = v["delta"]["text"].as_str() {
                self.text.push_str(text);
            }
        }
        if v["type"] == "message_stop" {
            self.finished = true;
        }
        if let Some(parts) = v["candidates"][0]["content"]["parts"].as_array() {
            for part in parts.iter().filter(|p| p["thought"] != true) {
                if let Some(text) = part["text"].as_str() {
                    self.text.push_str(text);
                }
            }
        }
        if !v["candidates"][0]["finishReason"].is_null() {
            self.finished = true;
        }
        let usage = if v["usage"].is_object() { &v["usage"] } else { &v["message"]["usage"] };
        self.input = usage["prompt_tokens"]
            .as_u64()
            .or(usage["input_tokens"].as_u64())
            .or(v["usageMetadata"]["promptTokenCount"].as_u64())
            .or(self.input);
        self.output = usage["completion_tokens"]
            .as_u64()
            .or(usage["output_tokens"].as_u64())
            .or(v["usageMetadata"]["candidatesTokenCount"].as_u64())
            .or(self.output);
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_utf8_and_terminal() {
        let wire = "data: {\"choices\":[{\"delta\":{\"content\":\"héllo\"}}]}\r\n\r\ndata: [DONE]\n\n";
        let mut stream = Stream::default();
        for b in wire.as_bytes() {
            stream.push(&[*b]).unwrap();
        }
        stream.finish().unwrap();
        assert_eq!(stream.text, "héllo");
    }
    #[test]
    fn incomplete_is_failure() {
        let mut stream = Stream::default();
        stream.push(b"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n").unwrap();
        assert!(stream.finish().is_err());
    }
}
