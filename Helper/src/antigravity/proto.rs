//! Minimal protobuf wire-format reader.
//!
//! Antigravity stores its conversation state as serialized protobuf blobs
//! inside SQLite, and Google does not ship the matching `.proto` files. This
//! reader walks the wire format by field number only, so unknown or renumbered
//! fields are skipped instead of failing the whole scan.

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Value<'a> {
    Varint(u64),
    Fixed64(u64),
    Bytes(&'a [u8]),
    Fixed32(u32),
}

impl<'a> Value<'a> {
    pub fn as_varint(self) -> Option<u64> {
        match self {
            Self::Varint(value) => Some(value),
            _ => None,
        }
    }

    pub fn as_bytes(self) -> Option<&'a [u8]> {
        match self {
            Self::Bytes(value) => Some(value),
            _ => None,
        }
    }
}

/// Iterates the top-level fields of one encoded message.
pub struct Fields<'a> {
    buffer: &'a [u8],
    offset: usize,
}

impl<'a> Fields<'a> {
    pub fn new(buffer: &'a [u8]) -> Self {
        Self { buffer, offset: 0 }
    }
}

impl<'a> Iterator for Fields<'a> {
    type Item = (u32, Value<'a>);

    fn next(&mut self) -> Option<Self::Item> {
        let (key, offset) = read_varint(self.buffer, self.offset)?;
        self.offset = offset;
        let number = u32::try_from(key >> 3).ok()?;
        if number == 0 {
            return None;
        }
        match key & 0x07 {
            0 => {
                let (value, offset) = read_varint(self.buffer, self.offset)?;
                self.offset = offset;
                Some((number, Value::Varint(value)))
            }
            1 => {
                let end = self.offset.checked_add(8)?;
                let slice = self.buffer.get(self.offset..end)?;
                self.offset = end;
                let mut bytes = [0u8; 8];
                bytes.copy_from_slice(slice);
                Some((number, Value::Fixed64(u64::from_le_bytes(bytes))))
            }
            2 => {
                let (length, offset) = read_varint(self.buffer, self.offset)?;
                let length = usize::try_from(length).ok()?;
                let end = offset.checked_add(length)?;
                let slice = self.buffer.get(offset..end)?;
                self.offset = end;
                Some((number, Value::Bytes(slice)))
            }
            5 => {
                let end = self.offset.checked_add(4)?;
                let slice = self.buffer.get(self.offset..end)?;
                self.offset = end;
                let mut bytes = [0u8; 4];
                bytes.copy_from_slice(slice);
                Some((number, Value::Fixed32(u32::from_le_bytes(bytes))))
            }
            _ => None,
        }
    }
}

fn read_varint(buffer: &[u8], mut offset: usize) -> Option<(u64, usize)> {
    let mut value = 0u64;
    let mut shift = 0u32;
    loop {
        let byte = *buffer.get(offset)?;
        offset += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some((value, offset));
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
}

pub fn fields(buffer: &[u8]) -> Fields<'_> {
    Fields::new(buffer)
}

/// Returns the last occurrence of `number`, matching protobuf merge semantics.
pub fn field<'a>(buffer: &'a [u8], number: u32) -> Option<Value<'a>> {
    fields(buffer)
        .filter(|(field_number, _)| *field_number == number)
        .map(|(_, value)| value)
        .last()
}

/// Resolves a nested field path such as `[5, 9, 2]`.
pub fn path<'a>(buffer: &'a [u8], numbers: &[u32]) -> Option<Value<'a>> {
    let (last, parents) = numbers.split_last()?;
    let mut current = buffer;
    for number in parents {
        current = field(current, *number)?.as_bytes()?;
    }
    field(current, *last)
}

pub fn message<'a>(buffer: &'a [u8], numbers: &[u32]) -> Option<&'a [u8]> {
    path(buffer, numbers)?.as_bytes()
}

pub fn varint(buffer: &[u8], numbers: &[u32]) -> Option<u64> {
    path(buffer, numbers)?.as_varint()
}

pub fn integer(buffer: &[u8], numbers: &[u32]) -> Option<i64> {
    i64::try_from(varint(buffer, numbers)?).ok()
}

pub fn string<'a>(buffer: &'a [u8], numbers: &[u32]) -> Option<&'a str> {
    let bytes = message(buffer, numbers)?;
    let text = std::str::from_utf8(bytes).ok()?;
    (!text.trim().is_empty()).then_some(text)
}

/// Reads a `google.protobuf.Timestamp` as milliseconds since the Unix epoch.
pub fn timestamp_ms(buffer: &[u8], numbers: &[u32]) -> Option<i64> {
    let timestamp = message(buffer, numbers)?;
    let seconds = integer(timestamp, &[1]).unwrap_or_default();
    let nanos = integer(timestamp, &[2]).unwrap_or_default();
    seconds
        .checked_mul(1_000)
        .and_then(|value| value.checked_add(nanos / 1_000_000))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_nested_fields() {
        // field 1 { field 2: 300 }, field 3: "ok"
        let blob = [0x0a, 0x03, 0x10, 0xac, 0x02, 0x1a, 0x02, b'o', b'k'];
        assert_eq!(integer(&blob, &[1, 2]), Some(300));
        assert_eq!(string(&blob, &[3]), Some("ok"));
        assert_eq!(integer(&blob, &[9]), None);
    }

    #[test]
    fn reads_timestamps_in_milliseconds() {
        // field 1 { seconds: 2, nanos: 500000000 }
        let blob = [0x0a, 0x08, 0x08, 0x02, 0x10, 0x80, 0xca, 0xb5, 0xee, 0x01];
        assert_eq!(timestamp_ms(&blob, &[1]), Some(2_500));
    }
}
