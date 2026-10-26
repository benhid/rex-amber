// Amber's landing page: reveal on scroll, copy buttons, the pencil marks, and
// the two WebGL pieces (the logo and the amber resin behind the mock windows).

const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Reveal ----------------------------------------------------------------------

const reveal = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add("in");
    reveal.unobserve(entry.target);
  }
}, { threshold: 0.15 });
document.querySelectorAll(".reveal").forEach((el) => reveal.observe(el));

// Copy buttons ------------------------------------------------------------------

// Copies the commands of a .cmd block, without comments or "$ " prompts.
function commandsIn(block) {
  return block.querySelector("pre").textContent
    .split("\n")
    .filter((line) => line.trim() && !line.trim().startsWith("#"))
    .map((line) => line.replace(/^\$ /, ""))
    .join("\n");
}

// Without the clipboard API (insecure context, denied permission), select the
// commands so the person can copy them with ⌘C.
function selectCommands(block) {
  const range = document.createRange();
  range.selectNodeContents(block.querySelector("pre"));
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

document.querySelectorAll(".copy").forEach((button) => {
  const block = button.closest(".cmd");
  const status = block.querySelector("[role=status]");
  let reset;
  button.addEventListener("click", async () => {
    const text = commandsIn(block);
    let ok = true;
    try { await navigator.clipboard.writeText(text); } catch { ok = false; selectCommands(block); }
    button.textContent = ok ? "Copied" : "Press ⌘C";
    button.classList.toggle("done", ok);
    status.textContent = ok ? "Commands copied" : "Couldn't copy. The commands are selected: press Command C.";
    clearTimeout(reset);
    reset = setTimeout(() => {
      button.textContent = "Copy";
      button.classList.remove("done");
      status.textContent = "";
    }, 1600);
  });
});

// Pencil marks --------------------------------------------------------------------

// Each mark starts after its delay. Once the last one is drawn, the marks are
// pinned: Safari doesn't always keep an SVG stroke animation's end state.
const proof = document.getElementById("proof");
const DELAYS = { t0: 0.2, t1: 0.7, t2: 1.2, t3: 1.7, t4: 2.4, t5: 2.9, t6: 3.6, t7: 4.3 };
const LONGEST_ANIMATION = 0.9;
for (const [cls, delay] of Object.entries(DELAYS)) {
  proof.querySelectorAll("." + cls).forEach((el) => (el.style.animationDelay = delay + "s"));
}
const drawnAfter = (Math.max(...Object.values(DELAYS)) + LONGEST_ANIMATION + 0.3) * 1000;
new IntersectionObserver(([entry], observer) => {
  if (!entry.isIntersecting) return;
  observer.disconnect();
  proof.classList.add("play");
  setTimeout(() => proof.classList.add("drawn"), drawnAfter);
}, { threshold: 0.3 }).observe(proof);

// WebGL -------------------------------------------------------------------------------

const VERTEX = "attribute vec2 p; void main() { gl_Position = vec4(p, 0., 1.); }";

// Shared by both shaders. High precision when the GPU has it: in mediump, many
// phones run fp16, which turns noise blocky. The hash avoids sin() for the same reason.
const COMMON = `
  #ifdef GL_FRAGMENT_PRECISION_HIGH
  precision highp float;
  #else
  precision mediump float;
  #endif
  float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
  }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3. - 2. * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
  }
  float fbm(vec2 p) {
    float v = 0., a = .5;
    for (int i = 0; i < OCTAVES; i++) { v += a * noise(p); p *= 2.02; a *= .5; }
    return v;
  }
`;

// Time loops every 1000 s so it never grows large enough to lose precision.
const TIME_LOOP = 1000;

// A canvas that draws one full-screen shader. It sizes itself, only animates
// while on screen and the tab is visible, draws a single frame when motion is
// reduced, and rebuilds itself if the GPU drops the context.
class ShaderCanvas {
  constructor(canvas, fragment, { octaves, scale, prepare, onLost, onReady }) {
    this.canvas = canvas;
    this.source = `#define OCTAVES ${octaves}\n${COMMON}\n${fragment}`;
    this.scale = scale;           // device pixels per CSS pixel
    this.prepare = prepare;       // (gl, uniform) => void, after every build and resize
    this.onLost = onLost;
    this.onReady = onReady;
    this.visible = true;
    this.frame = this.frame.bind(this);
    this.start = performance.now();

    this.gl = canvas.getContext("webgl", { antialias: false, premultipliedAlpha: true });
    if (!this.gl) return;

    canvas.addEventListener("webglcontextlost", (event) => {
      event.preventDefault();
      this.ready = false;
      this.onLost?.();
    });
    canvas.addEventListener("webglcontextrestored", () => this.build());

    new ResizeObserver(() => this.resize()).observe(canvas);
    new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      this.request();
    }).observe(canvas);
    document.addEventListener("visibilitychange", () => this.request());

    this.build();
  }

  build() {
    const gl = this.gl;
    const compile = (type, source) => {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) console.warn(gl.getShaderInfoLog(shader));
      return shader;
    };
    const program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, this.source));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
    gl.useProgram(program);

    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, "p");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);

    const locations = {};
    this.uniform = (name) => (locations[name] ??= gl.getUniformLocation(program, name));
    this.ready = true;
    this.resize();
    this.onReady?.();
  }

  resize() {
    if (!this.ready) return;
    const scale = typeof this.scale === "function" ? this.scale() : this.scale;
    this.canvas.width = Math.max(1, Math.round(this.canvas.clientWidth * scale));
    this.canvas.height = Math.max(1, Math.round(this.canvas.clientHeight * scale));
    this.gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    this.gl.uniform2f(this.uniform("res"), this.canvas.width, this.canvas.height);
    this.prepare?.(this.gl, this.uniform);
    this.draw(performance.now());  // resizing clears the canvas
  }

  draw(now) {
    const t = reduceMotion ? 2.5 : ((now - this.start) / 1000) % TIME_LOOP;
    this.gl.uniform1f(this.uniform("t"), t);
    this.gl.drawArrays(this.gl.TRIANGLES, 0, 3);
  }

  request() {
    if (this.running || reduceMotion) return;
    this.running = true;
    requestAnimationFrame(this.frame);
  }

  frame(now) {
    this.running = false;
    if (!this.ready || !this.visible || document.hidden) return;
    this.draw(now);
    this.request();
  }
}

// The resin ---------------------------------------------------------------------------

const RESIN = `
  uniform vec2 res; uniform float t;
  void main() {
    vec2 uv = gl_FragCoord.xy / res.y;
    vec2 w = uv * 1.25;
    vec2 o = vec2(fbm(w + vec2(0., t * .05)), fbm(w + vec2(5.2, 1.3) - t * .04));
    float f = fbm(w + 2.2 * o + vec2(t * .02, -t * .015));
    float veins = smoothstep(.82, 1., 1. - abs(2. * f - 1.));

    // Light resin at the top left, deeper towards the bottom right.
    vec2 q = gl_FragCoord.xy / res;
    float depth = clamp(length((q - vec2(.22, .95)) * vec2(1., .8)), 0., 1.);
    vec3 light = vec3(.99, .91, .74), honey = vec3(.95, .72, .38), deep = vec3(.74, .4, .14);
    vec3 c = mix(light, honey, smoothstep(.0, .65, depth));
    c = mix(c, deep, smoothstep(.55, 1.05, depth) * .85);
    c *= .94 + .14 * f;
    c = mix(c, vec3(1., .95, .84), veins * .28);
    c += vec3(.12, .07, .02) * (hash(gl_FragCoord.xy + fract(t) * 97.) - .5) * .25;
    gl_FragColor = vec4(c, 1.);
  }
`;

// Soft and slow, so half resolution is plenty.
document.querySelectorAll("canvas.resin").forEach((canvas) => {
  new ShaderCanvas(canvas, RESIN, { octaves: 5, scale: 0.5 }).request();
});

// The logo ----------------------------------------------------------------------------

// One canvas paints the stone and the word next to it. The letters reflect the
// light moving inside the stone, fading as they get further away.
const LOGO = `
  uniform vec2 res; uniform float t, scale; uniform sampler2D word; uniform vec3 ink;
  // An irregular, slightly faceted nugget of resin, tilted a little.
  float radius(float a) {
    float round_r = .62 + .07 * sin(2. * a + .5) + .045 * sin(3. * a - 1.2) + .02 * sin(5. * a + 2.1);
    float k = 6.2832 / 7.;
    float facet = cos(k * .5) / cos(mod(a + .3, k) - k * .5);
    return round_r * mix(1., facet, .35);
  }
  vec2 frame(vec2 p) { p = mat2(.94, -.34, .34, .94) * p; return p * vec2(1., .86); }
  float shape(vec2 p) { p = frame(p); return length(p) - radius(atan(p.y, p.x)); }
  float height(vec2 p) {
    p = frame(p);
    float r = length(p) / radius(atan(p.y, p.x));
    return sqrt(max(0., 1. - r * r));
  }
  // Currents of light swirling through the resin. x = swirl, y = veins.
  vec2 magic(vec2 p) {
    vec2 w = p * 2.3;
    vec2 o = vec2(fbm(w + vec2(0., t * .32)), fbm(w + vec2(5.2, 1.3) - t * .27));
    float f = fbm(w + 2.4 * o + vec2(t * .12, -t * .09));
    return vec2(pow(f, 2.2), smoothstep(.8, 1., 1. - abs(2. * f - 1.)));
  }

  vec4 stone(vec2 uv) {
    float d = shape(uv);
    float inside = smoothstep(.012, -.012, d);
    float depth = clamp(-d / .5, 0., 1.);
    float e = .012;
    vec2 g = vec2(height(uv + vec2(e, 0.)) - height(uv - vec2(e, 0.)), height(uv + vec2(0., e)) - height(uv - vec2(0., e))) / (2. * e);
    vec3 n = normalize(vec3(-g * .22, 1.));
    vec3 L = normalize(vec3(-.55, .65, .55));
    float diff = max(dot(n, L), 0.);
    float spec = pow(max(dot(reflect(-L, n), vec3(0., 0., 1.)), 0.), 70.);

    vec3 deep = vec3(.5, .19, .03), body = vec3(.95, .56, .13), glowc = vec3(1., .88, .55);
    vec3 c = mix(deep, body, smoothstep(0., .6, depth));
    float through = smoothstep(1., .0, length((uv - vec2(.16, -.18)) * vec2(1., 1.2))) * depth;
    c = mix(c, glowc, through * .55);

    vec2 m = magic(uv);
    c = mix(c * (.8 + .45 * m.x), vec3(1., .92, .66), m.y * .8 * depth);
    c += vec3(1., .7, .28) * m.x * .35 * depth;

    // Tiny sparks drifting and twinkling inside.
    vec2 sp = uv * 8. + vec2(0., t * .25);
    vec2 id = floor(sp), fp = fract(sp) - .5;
    float rnd = hash(id);
    float twinkle = pow(.5 + .5 * sin(t * 2.6 + rnd * 40.), 10.);
    c += vec3(1., .96, .82) * smoothstep(.09, .0, length(fp - (vec2(hash(id + 1.7), hash(id + 3.1)) - .5) * .6)) * step(.78, rnd) * twinkle * depth * 1.4;

    c *= .82 + .26 * diff;
    c += vec3(1., .97, .9) * spec * .9;
    float halo = exp(-max(d, 0.) * 10.) * (1. - inside) * (.18 + .07 * sin(t * 1.1));
    return vec4(c * inside + vec3(.97, .64, .26) * halo, inside + halo);
  }

  void main() {
    vec2 px = gl_FragCoord.xy;
    vec2 uv = (px - vec2(20. * scale, res.y * .5)) / (20. * scale) * 1.04;
    vec4 s = stone(uv);

    float a = texture2D(word, vec2(px.x / res.x, 1. - px.y / res.y)).a;
    float reach = exp(-max(shape(uv), 0.) * .8);
    vec2 m = magic(normalize(uv) * .38 + uv * .12);
    vec3 lit = mix(vec3(.88, .45, .08), vec3(1., .82, .4), m.y * .8 + m.x * .4);
    vec3 color = mix(ink, lit, clamp(reach * (.75 + .8 * m.x + .6 * m.y), 0., 1.));
    gl_FragColor = s + vec4(color * a, a) * (1. - s.a);
  }
`;

(function logo() {
  const link = document.querySelector(".logo");
  const canvas = document.getElementById("logo-fx");
  const STONE = 40, GAP = 21, SIZE = 25.6, HEIGHT = 44;
  const font = `italic 500 ${SIZE}px Erode, Georgia, serif`;
  const dpr = () => Math.min(devicePixelRatio || 1, 2);

  // The ink color in CSS, as RGB the shader can use.
  function inkRGB() {
    const probe = document.createElement("canvas").getContext("2d");
    probe.fillStyle = "#2a2420";
    probe.fillStyle = getComputedStyle(document.documentElement).getPropertyValue("--ink").trim() || probe.fillStyle;
    probe.fillRect(0, 0, 1, 1);
    const [r, g, b] = probe.getImageData(0, 0, 1, 1).data;
    return [r / 255, g / 255, b / 255];
  }

  // Sizes the canvas to fit the word, before the shader canvas measures it.
  const measure = document.createElement("canvas").getContext("2d");
  measure.font = font;
  const textX = STONE + GAP - 20;
  const width = Math.ceil(textX + measure.measureText("amber").width + 10);

  function prepare(gl, uniform) {
    const scale = dpr();
    const text = document.createElement("canvas");
    text.width = canvas.width;
    text.height = canvas.height;
    const ctx = text.getContext("2d");
    ctx.scale(scale, scale);
    ctx.font = font;
    if ("letterSpacing" in ctx) ctx.letterSpacing = `${-0.03 * SIZE}px`;
    ctx.fillStyle = "#fff";
    ctx.fillText("amber", textX, HEIGHT / 2 + SIZE * 0.3);

    gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, text);
    gl.uniform1f(uniform("scale"), scale);
    gl.uniform3fv(uniform("ink"), inkRGB());
  }

  document.fonts.load(font).finally(() => {
    canvas.style.width = width + "px";
    canvas.style.height = HEIGHT + "px";
    const shader = new ShaderCanvas(canvas, LOGO, {
      octaves: 4,
      scale: dpr,
      prepare,
      onLost: () => link.classList.remove("fx-on"),
      onReady: () => link.classList.add("fx-on"),
    });
    if (!shader.ready) return;
    shader.request();

    // Moving the window to a screen with another pixel density.
    const watchDensity = () => matchMedia(`(resolution: ${devicePixelRatio}dppx)`).addEventListener("change", () => {
      shader.resize();
      watchDensity();
    }, { once: true });
    watchDensity();
  });
})();
