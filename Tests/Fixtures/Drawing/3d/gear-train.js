// Three meshing spur gears on a plate: the small idler turns fastest.
say("Gears trade speed for turning force.");
const f = figure(640, 140, 620, 440, { look: "studio", tilt: 24, turn: -18 });
const plate = f.box({ size: [5.6, 3.2, 0.14], at: [0.45, 0.15, -0.32], round: 0.06, mat: "wood" });
const gears = [
  { teeth: 24, r: 1.2, at: [-1.2, 0, 0], mat: "brass", name: "driver" },
  { teeth: 12, r: 0.6, at: [0.6, 0, 0], mat: "steel", name: "idler" },
  { teeth: 18, r: 0.9, at: [0.6 + 1.5 * Math.cos(0.7), 1.5 * Math.sin(0.7), 0], mat: "copper", name: "output" },
];
// Each gear turns so a tooth of one sits in a gap of the next.
let phase = 0;
const handles = gears.map((g, i) => {
  if (i > 0) {
    const prev = gears[i - 1];
    const dir = Math.atan2(g.at[1] - prev.at[1], g.at[0] - prev.at[0]) * 57.2958;
    const prevTooth = 360 / prev.teeth, tooth = 360 / g.teeth;
    const contactPrev = ((dir - prev.phase) % prevTooth + prevTooth) % prevTooth;
    phase = dir + 180 + tooth / 2 + contactPrev * (prev.teeth / g.teeth);
  }
  g.phase = phase;
  const gear = f.gear({ teeth: g.teeth, r: g.r, depth: 0.16, width: 0.26, hole: 0.12, at: g.at, rot: [0, 0, phase], mat: g.mat, name: g.name });
  f.cylinder({ r: 0.1, h: 0.62, axis: "z", at: [g.at[0], g.at[1], -0.05], mat: "chrome" });
  return gear;
});
handles[0].spin({ axis: "z", rpm: 8 });
handles[1].spin({ axis: "z", rpm: -16 });
handles[2].spin({ axis: "z", rpm: 16 * 12 / 18 });
f.label(handles[0], "driver, 24 teeth", { side: "left" });
f.label(handles[1], "idler, 12 teeth");
f.label(handles[2], "output, 18 teeth", { side: "right" });
f.readout({ ratio: "24 : 18", output: "10.7 rpm" });
