/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Display
import GroupChatClient.GroupChatKatzenqt1.Presentation

/-! # How jam words and filters what the core says -/

namespace Jam

open GroupChatClient.GroupChatKatzenqt1

def presentation : Presentation where
  name s := (Display.name s).text.text
  outgoing := Display.outgoing
  newGroup := "a new group: /invite with a member's voucher code adds them"
  voucherMinted code _ file :=
    s!"give this voucher code to a member of the group, and wait (it is also in {file} in the state directory): {code}"

end Jam
