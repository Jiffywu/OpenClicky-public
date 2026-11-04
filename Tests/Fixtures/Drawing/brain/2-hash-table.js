step(1)
say("A hash table turns a key into a slot number, so it can jump straight there.")
const card = paper(90, 110, 1100, 600, {title: "Hash table", board: "grid"});
const key = box(card.x + 40, card.y + 120, 200, 80, {label: "\"apple\""});
const fn = box(card.x + 360, card.y + 120, 220, 80, {label: "hash function"});
arrow([key.right + 8, key.cy], [fn.left - 8, fn.cy]);
const slots = [];
for (let i = 0; i < 6; i++) {
  slots.push(box(card.x + 40 + i * 170, card.y + 330, 140, 70, {label: "slot " + i}));
}
step(2)
say("The hash function turns the key into a number, here slot three.")
arrow([fn.cx, fn.bottom + 8], [slots[3].cx, slots[3].top - 8], {label: "index 3"});
step(3)
say("Finding apple means one calculation and one check, however big the table gets.")
text(card.x + 40, card.y + 470, "Lookup: hash the key, go to that slot, check it. Usually one step.", {size: 18});
step(4)
say("If two keys land in the same slot, the table keeps both in a short list there.")
text(card.x + 40, card.y + 510, "That clash is a collision. Good hash functions make them rare.", {size: 18});
button(card.x + 40, card.y + 560, "Why is the hash function so fast?")
