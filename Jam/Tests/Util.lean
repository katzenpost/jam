/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

namespace Jam.Tests

abbrev TestM := StateT (Nat × Nat) IO

def check (name : String) (ok : Bool) : TestM Unit := do
  let (pass, fail) ← get
  if ok then set (pass + 1, fail)
  else
    IO.println s!"FAIL {name}"
    set (pass, fail + 1)

end Jam.Tests
