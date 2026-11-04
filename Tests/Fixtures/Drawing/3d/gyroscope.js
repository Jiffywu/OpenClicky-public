// A gyroscope: a heavy spinning rotor held by two gimbal rings on a stand.
say("This is a gyroscope: a heavy rotor spinning inside two gimbal rings.");
const f = figure(700, 150, 560, 460, { look: "studio", tilt: 20, turn: -28 });
const stand = f.cylinder({ r: 0.95, h: 0.14, round: 0.05, at: [0, -1.78, 0], mat: "iron" });
f.cylinder({ from: [0, -1.72, 0], to: [0, -1.27, 0], r: 0.07, mat: "steel" });
const gimbal = f.torus({ r: 1.25, tube: 0.055, axis: "z", mat: "brass" });
const inner = f.torus({ r: 1.06, tube: 0.045, axis: "x", mat: "brass" });
f.sphere({ r: 0.08, at: [1.25, 0, 0], mirror: "x", mat: "chrome" });
f.sphere({ r: 0.07, at: [0, 1.06, 0], mirror: "y", mat: "chrome" });
const axle = f.cylinder({ from: [0, -1.06, 0], to: [0, 1.06, 0], r: 0.035, mat: "chrome" });
const rotor = f.lathe({
  profile: [[0, -0.12], [0.86, -0.12], [0.9, -0.06], [0.9, 0.06], [0.86, 0.12], [0.3, 0.12], [0.26, 0.2], [0, 0.2]],
  round: 0.02, mat: "steel",
});
f.cylinder({ r: 0.3, h: 0.02, at: [0, -0.13, 0], mat: "red", name: "balance mark", arc: 60 });
rotor.spin({ axis: "y", rpm: 240 });
say("The rotor keeps its axis while the rings let the frame turn around it.");
f.label(rotor, "rotor");
f.label(gimbal, "gimbal ring", { side: "left" });
f.label(stand, "stand");
