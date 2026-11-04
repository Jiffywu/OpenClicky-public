step(1)
say("A spinning gyroscope resists tipping because of angular momentum.")
const f = figure(340, 130, 600, 560, { look: "studio", tilt: 18, spin: 3 });
const rotor = f.cylinder({ r: 0.9, h: 0.18, round: 0.03, axis: "z", mat: "brass" });
f.torus({ r: 1.25, tube: 0.04, mat: "steel" });
f.torus({ r: 1.25, tube: 0.04, mat: "steel", rot: [90, 0, 0] });
f.cylinder({ from: [0, -1.6, 0], to: [0, 1.6, 0], r: 0.05, mat: "chrome" });
rotor.spin({ axis: "z", rpm: 90 });
f.label(rotor, "spinning rotor", {side: "right"});
step(2)
say("Spinning mass has a direction of motion, and that direction wants to stay put.")
step(3)
say("A push on the axle tries to tip it, but the rotor's spin turns that push sideways instead.")
const card = paper(40, 150, 260, 300, {title: "Why it stays up", board: "plain"});
write(card.x + 10, card.y + 40, "Spin = angular momentum.\nTipping force makes it\nprecess sideways, not fall.\nFriction slowly slows it.")
