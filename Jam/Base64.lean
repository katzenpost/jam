/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

/-! # Base64

The standard alphabet with padding, as Python's `b64encode` writes a voucher code. -/

namespace Jam.Base64

def alphabet : String := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def charAt (n : Nat) : Char := (alphabet.toList.getD n 'A')

def encode (b : ByteArray) : String := Id.run do
  let bytes := b.data
  let mut out := ""
  let mut i := 0
  while i < bytes.size do
    let b0 := bytes[i]!.toNat
    let b1 := (bytes[i + 1]?.map (·.toNat)).getD 0
    let b2 := (bytes[i + 2]?.map (·.toNat)).getD 0
    let n := b0 * 65536 + b1 * 256 + b2
    out := out.push (charAt (n / 262144 % 64))
    out := out.push (charAt (n / 4096 % 64))
    out := out.push (if i + 1 < bytes.size then charAt (n / 64 % 64) else '=')
    out := out.push (if i + 2 < bytes.size then charAt (n % 64) else '=')
    i := i + 3
  return out

def valueOf (c : Char) : Option Nat :=
  if 'A' ≤ c ∧ c ≤ 'Z' then some (c.toNat - 'A'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'z' then some (c.toNat - 'a'.toNat + 26)
  else if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat + 52)
  else if c = '+' then some 62
  else if c = '/' then some 63
  else none

/-- The bytes `s` encodes, ignoring surrounding whitespace; `none` when it is not base64. -/
def decode (s : String) : Option ByteArray := do
  let cs := s.trimAscii.toString.toList
  if cs.length % 4 ≠ 0 then none
  let pad := (cs.reverse.takeWhile (· = '=')).length
  if pad > 2 then none
  let body := cs.take (cs.length - pad)
  let vals ← body.mapM valueOf
  let vals := vals ++ List.replicate pad 0
  let mut out := ByteArray.empty
  let mut rest := vals
  while rest.length ≥ 4 do
    let n := rest[0]! * 262144 + rest[1]! * 4096 + rest[2]! * 64 + rest[3]!
    out := out.push (n / 65536).toUInt8 |>.push (n / 256 % 256).toUInt8 |>.push (n % 256).toUInt8
    rest := rest.drop 4
  return out.extract 0 (out.size - pad)

end Jam.Base64
