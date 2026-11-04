// Benzene: six carbons in a ring, each with a hydrogen, and the shared electron cloud above and below.
say("Benzene is a flat ring of six carbon atoms.");
const f = figure(680, 160, 540, 440, { look: "studio", tilt: 32, turn: 12, spin: 3 });
const ring = f.group({});
const carbon = f.sphere({ r: 0.32, at: [1.4, 0, 0], mat: "plastic", color: "charcoal", parent: ring, copies: { count: 6, around: "y" } });
f.cylinder({ from: [1.4, 0, 0], to: [0.7, 0, 1.2124], r: 0.09, mat: "gloss", color: "grey", parent: ring, copies: { count: 6, around: "y" } });
const hydrogen = f.sphere({ r: 0.2, at: [2.45, 0, 0], mat: "ceramic", parent: ring, copies: { count: 6, around: "y" } });
f.cylinder({ from: [1.65, 0, 0], to: [2.3, 0, 0], r: 0.07, mat: "gloss", color: "white", parent: ring, copies: { count: 6, around: "y" } });
say("Their shared electrons form a cloud above and below the ring.");
const cloud = f.torus({ r: 1.4, tube: 0.3, at: [0, 0.42, 0], mat: "glass", color: "teal", mirror: "y", parent: ring });
cloud.pulse({ amount: 0.04, period: 2 });
f.label(carbon, "carbon");
f.label(hydrogen, "hydrogen", { side: "right" });
f.label(cloud, "π electron cloud", { side: "left" });
