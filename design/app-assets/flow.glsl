precision highp float;

/** @resolution */
uniform vec2 u_resolution;

/** @time */
uniform float u_time;

/**
 * @label Speed
 * @default 1
 * @range 0, 4
 */
uniform float u_speed;

/**
 * @label Density
 * @default 0.42
 * @range 0, 1
 */
uniform float u_density;

/**
 * @label Dot Scale
 * @default 1
 * @range 0.5, 4
 */
uniform float u_dot;

/**
 * @label VPN Amsterdam
 * @color
 * @default #C8F542
 */
uniform vec3 u_colA;

/**
 * @label VPN New York
 * @color
 * @default #A78BFA
 */
uniform vec3 u_colB;

/**
 * @label Direct
 * @color
 * @default #6FA8FF
 */
uniform vec3 u_colC;

/**
 * @label Blocked
 * @color
 * @default #FF6B5E
 */
uniform vec3 u_colD;

const vec2 SIZE = vec2(800.0, 600.0);

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float ease(float t) {
  t = clamp(t, 0.0, 1.0);
  return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float pinch(float t) {
  return 1.0 - 0.5 * sin(3.14159 * clamp(t, 0.0, 1.0));
}

vec4 flow(vec2 p, float y0, float y1, float h, vec3 col, float seed, float spd) {
  float t = p.x / SIZE.x;
  float c = mix(y0, y1, ease(t));
  float s = pinch(t);
  float rel = (p.y - c) / s;
  float hh = h * 0.5;
  float LS = 3.4 * u_dot;
  float spread = hh + 16.0 * u_dot;
  if (abs(rel) > spread + 10.0 * u_dot) return vec4(0.0);

  vec4 acc = vec4(0.0);
  float g = exp(-pow(rel / (hh + 2.0), 2.0)) * 0.022;
  acc += vec4(mix(vec3(0.9), col, smoothstep(0.2, 0.9, t)) * g, g);

  float lane0 = floor(rel / LS);
  for (int k = -2; k <= 2; k++) {
    float lane = lane0 + float(k);
    float lc = (lane + 0.5) * LS;
    if (abs(lc) > spread) continue;
    float outside = max(abs(lc) - hh, 0.0);
    float dens = u_density * exp(-outside * 0.22 / u_dot);
    float hl = hash(vec2(lane, seed));
    float v = spd * (0.55 + 0.9 * hl) * u_speed;
    float cw = (9.0 + 18.0 * hash(vec2(seed, lane * 1.7))) * u_dot;
    float xs = p.x - u_time * v;
    float cell = floor(xs / cw);
    float hc = hash(vec2(cell + seed * 13.0, lane));
    if (hc > dens) continue;
    float px = (cell + 0.3 + 0.4 * hash(vec2(cell, lane + seed))) * cw + u_time * v;
    float tp = px / SIZE.x;
    float cp = mix(y0, y1, ease(tp));
    float op = lc + (hash(vec2(lane * 3.1, cell + seed)) - 0.5) * LS * 0.6;
    float py = cp + op * pinch(tp);
    float r = (0.5 + 1.1 * pow(hash(vec2(cell * 0.7, lane * 1.3 + seed)), 3.0)) * u_dot;
    float d = length(p - vec2(px, py));
    float a = smoothstep(r + 0.7 * u_dot, r - 0.3 * u_dot, d);
    float tw = 0.45 + 0.55 * hash(vec2(cell * 1.9 + seed, lane * 0.3));
    tw *= 0.7 + 0.3 * sin(u_time * 2.5 + hc * 60.0);
    a *= tw;
    vec3 pc = mix(vec3(0.92), col, smoothstep(0.15, 0.85, tp));
    acc += vec4(pc * a, a);
  }
  return acc;
}

void main() {
  vec2 p = gl_FragCoord.xy / u_resolution * SIZE;
  p.y = SIZE.y - p.y;
  vec4 c = vec4(0.0);
  c += flow(p, 30.0, 350.0, 60.0, u_colC, 1.0, 38.0);
  c += flow(p, 115.0, 35.0, 70.0, u_colA, 2.0, 46.0);
  c += flow(p, 215.0, 425.0, 90.0, u_colC, 3.0, 34.0);
  c += flow(p, 315.0, 105.0, 70.0, u_colA, 4.0, 50.0);
  c += flow(p, 365.0, 485.0, 30.0, u_colC, 5.0, 40.0);
  c += flow(p, 385.0, 585.0, 10.0, u_colD, 6.0, 30.0);
  c += flow(p, 435.0, 255.0, 50.0, u_colB, 7.0, 44.0);
  c += flow(p, 505.0, 165.0, 50.0, u_colA, 8.0, 42.0);
  c += flow(p, 570.0, 520.0, 40.0, u_colC, 9.0, 32.0);
  c += flow(p, 595.0, 595.0, 10.0, u_colD, 10.0, 26.0);
  gl_FragColor = clamp(c, 0.0, 1.0);
}
