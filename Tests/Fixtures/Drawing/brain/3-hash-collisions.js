step(1)
say("Both keys get stored in the same slot, chained together in a short list.")
const card = paper(90, 120, 1100, 560, {title: "Two keys, one slot", board: "grid"});
const k1 = box(card.x + 40, card.y + 60, 180, 70, {label: "\"apple\""});
const k2 = box(card.x + 40, card.y + 220, 180, 70, {label: "\"plum\""});
const slot = box(card.x + 380, card.y + 140, 160, 70, {label: "slot 3"});
arrow([k1.right + 8, k1.cy], [slot.left - 8, slot.cy - 10]);
arrow([k2.right + 8, k2.cy], [slot.left - 8, slot.cy + 10]);
step(2)
say("The table stores the first key, then adds the second one to the same list.")
const a = box(card.x + 640, card.y + 60, 150, 70, {label: "apple"});
const b = box(card.x + 840, card.y + 60, 150, 70, {label: "plum"});
arrow([slot.right + 8, slot.cy], [a.left - 8, a.cy], {label: "next"});
arrow([a.right + 8, a.cy], [b.left - 8, b.cy], {label: "next"});
step(3)
say("To look up plum, the table checks each item in that short list.")
text(card.x + 40, card.y + 380, "Lookup: hash the key, then compare it against each item in that slot.", {size: 18, wrap: 1000});
text(card.x + 40, card.y + 430, "Short lists keep this quick. Too many collisions slow the table down.", {size: 18, wrap: 1000});
button(card.x + 40, card.y + 490, "How do tables avoid too many collisions?")
