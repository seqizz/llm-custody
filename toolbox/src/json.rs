//! A small JSON reader and writer.
//!
//! Two callers, both with modest needs: `nix profile list --json`, and the
//! one-line-per-message broker protocol. Pulling in serde would mean vendoring
//! it plus its proc-macro chain for a host that may have no network, which is
//! a poor trade for an object with five keys in it.
//!
//! Objects keep their keys in document order (a Vec, not a map): the profile
//! reports read better when elements come out in the order nix printed them,
//! and lookups here are over a handful of keys.

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(kv) => kv.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Num(n) if *n >= 0.0 => Some(*n as u64),
            _ => None,
        }
    }

    pub fn as_arr(&self) -> Option<&[Json]> {
        match self {
            Json::Arr(v) => Some(v),
            _ => None,
        }
    }

    /// Convenience for the protocol, where every field that matters is a
    /// string and an absent one is the same as an empty one.
    pub fn str_field(&self, key: &str) -> &str {
        self.get(key).and_then(|v| v.as_str()).unwrap_or("")
    }
}

pub fn parse(input: &str) -> Result<Json, String> {
    let bytes = input.as_bytes();
    let mut p = Parser { b: bytes, i: 0 };
    p.skip_ws();
    let v = p.value(0)?;
    p.skip_ws();
    if p.i != p.b.len() {
        return Err(format!("trailing data at byte {}", p.i));
    }
    Ok(v)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

/// Depth cap so a hostile or corrupt message cannot drive the recursive
/// descent into a stack overflow. Real nix output nests four or five deep.
const MAX_DEPTH: usize = 64;

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Result<u8, String> {
        self.b.get(self.i).copied().ok_or_else(|| "unexpected end of input".to_string())
    }

    fn eat(&mut self, c: u8) -> Result<(), String> {
        if self.peek()? != c {
            return Err(format!("expected '{}' at byte {}", c as char, self.i));
        }
        self.i += 1;
        Ok(())
    }

    fn lit(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.b[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(format!("unexpected token at byte {}", self.i))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err("too deeply nested".to_string());
        }
        self.skip_ws();
        match self.peek()? {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => Ok(Json::Str(self.string()?)),
            b't' => self.lit("true", Json::Bool(true)),
            b'f' => self.lit("false", Json::Bool(false)),
            b'n' => self.lit("null", Json::Null),
            _ => self.number(),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        self.eat(b'{')?;
        let mut out = Vec::new();
        self.skip_ws();
        if self.peek()? == b'}' {
            self.i += 1;
            return Ok(Json::Obj(out));
        }
        loop {
            self.skip_ws();
            let k = self.string()?;
            self.skip_ws();
            self.eat(b':')?;
            let v = self.value(depth + 1)?;
            out.push((k, v));
            self.skip_ws();
            match self.peek()? {
                b',' => self.i += 1,
                b'}' => {
                    self.i += 1;
                    return Ok(Json::Obj(out));
                }
                _ => return Err(format!("expected ',' or '}}' at byte {}", self.i)),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        self.eat(b'[')?;
        let mut out = Vec::new();
        self.skip_ws();
        if self.peek()? == b']' {
            self.i += 1;
            return Ok(Json::Arr(out));
        }
        loop {
            out.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.peek()? {
                b',' => self.i += 1,
                b']' => {
                    self.i += 1;
                    return Ok(Json::Arr(out));
                }
                _ => return Err(format!("expected ',' or ']' at byte {}", self.i)),
            }
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.eat(b'"')?;
        let mut out = String::new();
        loop {
            let c = self.peek()?;
            self.i += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let e = self.peek()?;
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return Err(format!("bad escape at byte {}", self.i)),
                    }
                }
                // Everything else is copied through as raw bytes and
                // validated as UTF-8 at the end of the run, which keeps
                // multi-byte characters intact without decoding them here.
                _ => {
                    let start = self.i - 1;
                    while self.i < self.b.len()
                        && self.b[self.i] != b'"'
                        && self.b[self.i] != b'\\'
                    {
                        self.i += 1;
                    }
                    match std::str::from_utf8(&self.b[start..self.i]) {
                        Ok(s) => out.push_str(s),
                        Err(_) => return Err("invalid UTF-8 in string".to_string()),
                    }
                }
            }
        }
    }

    fn unicode_escape(&mut self) -> Result<char, String> {
        let hi = self.hex4()?;
        // Surrogate pair: nix escapes nothing above the BMP in practice, but a
        // decoder that mangles one is worse than one that rejects it.
        if (0xD800..0xDC00).contains(&hi) {
            if self.b[self.i..].starts_with(b"\\u") {
                self.i += 2;
                let lo = self.hex4()?;
                if (0xDC00..0xE000).contains(&lo) {
                    let c = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                    return char::from_u32(c).ok_or_else(|| "bad surrogate pair".to_string());
                }
            }
            return Err("unpaired surrogate".to_string());
        }
        char::from_u32(hi).ok_or_else(|| "bad \\u escape".to_string())
    }

    fn hex4(&mut self) -> Result<u32, String> {
        if self.i + 4 > self.b.len() {
            return Err("truncated \\u escape".to_string());
        }
        let s = std::str::from_utf8(&self.b[self.i..self.i + 4])
            .map_err(|_| "bad \\u escape".to_string())?;
        let v = u32::from_str_radix(s, 16).map_err(|_| "bad \\u escape".to_string())?;
        self.i += 4;
        Ok(v)
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek()? == b'-' {
            self.i += 1;
        }
        while self.i < self.b.len()
            && matches!(self.b[self.i], b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-')
        {
            self.i += 1;
        }
        let s = std::str::from_utf8(&self.b[start..self.i]).unwrap_or("");
        s.parse::<f64>()
            .map(Json::Num)
            .map_err(|_| format!("bad number at byte {start}"))
    }
}

/// Escape one string into an already-open JSON context.
pub fn escape_into(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            // Control characters must be escaped for the output to be valid
            // JSON at all, and the protocol is newline-framed - an unescaped
            // one in a reason string would split the message in two.
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Builds one flat `{"k":"v",...}` message. The protocol has no nested objects
/// except the request list, which `Obj::raw` covers.
pub struct Obj {
    buf: String,
    empty: bool,
}

impl Obj {
    pub fn new() -> Self {
        Obj { buf: String::from("{"), empty: true }
    }

    fn sep(&mut self) {
        if !self.empty {
            self.buf.push(',');
        }
        self.empty = false;
    }

    pub fn str(mut self, k: &str, v: &str) -> Self {
        self.sep();
        escape_into(&mut self.buf, k);
        self.buf.push(':');
        escape_into(&mut self.buf, v);
        self
    }

    pub fn num(mut self, k: &str, v: u64) -> Self {
        self.sep();
        escape_into(&mut self.buf, k);
        let _ = write!(self.buf, ":{v}");
        self
    }

    /// For a value that is already JSON, i.e. an array built elsewhere.
    pub fn raw(mut self, k: &str, v: &str) -> Self {
        self.sep();
        escape_into(&mut self.buf, k);
        self.buf.push(':');
        self.buf.push_str(v);
        self
    }

    pub fn finish(mut self) -> String {
        self.buf.push('}');
        self.buf
    }
}
