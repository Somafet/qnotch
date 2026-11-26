// The hero backdrop's shader: a glow centered on the demo's top edge, its edges and colors pushed around by
// domain-warped noise. It renders at half resolution (it is all soft gradients), at most 30 frames a second,
// and only while the hero is on screen. Reduced motion gets one still frame.

const VERT = `attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}`;

const FRAG = `precision mediump float;
uniform vec2 res;uniform float t,k,dl;uniform vec2 focus;uniform vec3 bg,c1,c2,c3;
float h(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float n(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);
  return mix(mix(h(i),h(i+vec2(1,0)),f.x),mix(h(i+vec2(0,1)),h(i+1.),f.x),f.y);}
// Ordered (Bayer 8x8) threshold in [0,1), from the cell's position.
float b2(vec2 a){a=floor(a);return fract(dot(a,vec2(.5,a.y*.75)));}
float bayer(vec2 a){return b2(.25*a)*.0625+b2(.5*a)*.25+b2(a);}
float fbm(vec2 p){float v=0.,a=.5;for(int i=0;i<4;i++){v+=a*n(p);p=p*2.03+17.;a*=.5;}return v;}
void main(){
  vec2 uv=gl_FragCoord.xy/res;uv.y=1.-uv.y;
  vec2 p=(uv-focus)*vec2(res.x/res.y,1.);
  vec2 q=vec2(fbm(p*1.4+vec2(0.,t*.06)),fbm(p*1.4+vec2(5.2,1.3)-t*.05));
  vec2 w=p+(q-.5)*.7;
  float f=fbm(w*2.2+q*1.5+t*.03);
  float d=length(w*vec2(.55,w.y<0.?6.5:1.8));
  float m=smoothstep(.85,0.,d);
  m*=m*smoothstep(1.,.8,uv.y)*smoothstep(.05,.3,uv.y);
  vec3 col=mix(c1,c2,smoothstep(.35,.7,f));
  col=mix(col,c3,smoothstep(.5,.85,q.y)*smoothstep(.45,0.,d));
  float a=clamp(m*k,0.,1.);
  // Thin out the faintest dots first, so the glow's fringe (behind the copy) stays clean.
  if(dl>0.)a=floor(a*smoothstep(.05,.3,a)*dl+bayer(gl_FragCoord.xy))/dl;
  vec3 o=mix(bg,col,a);
  o+=(h(gl_FragCoord.xy+fract(t))-.5)/255.;
  gl_FragColor=vec4(o,1.);
}`;

const rgb = (css: string) => {
  const hex = css.trim().replace('#', '');
  const v = parseInt(hex.length === 3 ? hex.replace(/./g, '$&$&') : hex, 16);
  return [(v >> 16) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
};

export function mountBackdrop(root: HTMLElement) {
  const canvas = root.querySelector('canvas')!;
  const gl = canvas.getContext('webgl', { antialias: false, alpha: false, powerPreference: 'low-power' });
  if (!gl) return;

  const shader = (type: number, src: string) => {
    const s = gl.createShader(type)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return s;
  };
  const prog = gl.createProgram()!;
  gl.attachShader(prog, shader(gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
  gl.useProgram(prog);

  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const u = (name: string) => gl.getUniformLocation(prog, name);

  const hero = root.parentElement!;
  const focusEl = hero.querySelector<HTMLElement>('[data-backdrop-focus]');

  // Colors come from CSS, so the theme and the Windows/Mac switch only have to change custom properties.
  const readColors = () => {
    const cs = getComputedStyle(root);
    gl.uniform3fv(u('bg'), rgb(cs.getPropertyValue('--bg')));
    gl.uniform3fv(u('c1'), rgb(cs.getPropertyValue('--hb-1')));
    gl.uniform3fv(u('c2'), rgb(cs.getPropertyValue('--hb-2')));
    gl.uniform3fv(u('c3'), rgb(cs.getPropertyValue('--hb-3')));
    gl.uniform1f(u('k'), parseFloat(cs.getPropertyValue('--hb-strength')) || 0.8);
    // Dithered glows keep their pixels crisp; smooth ones are upscaled smoothly.
    const levels = parseFloat(cs.getPropertyValue('--hb-dither')) || 0;
    gl.uniform1f(u('dl'), levels);
    canvas.style.imageRendering = levels ? 'pixelated' : '';
  };

  const resize = () => {
    const w = Math.max(1, Math.round(hero.clientWidth / 2));
    const h = Math.max(1, Math.round(hero.clientHeight / 2));
    canvas.width = w;
    canvas.height = h;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(u('res'), w, h);
    const top = focusEl ? focusEl.getBoundingClientRect().top - hero.getBoundingClientRect().top : hero.clientHeight * 0.6;
    gl.uniform2f(u('focus'), 0.5, top / hero.clientHeight);
  };

  const still = matchMedia('(prefers-reduced-motion: reduce)');
  const start = performance.now() - 20_000; // start mid-drift, not from the seed's first frame
  let visible = true;
  let raf = 0;
  let last = 0;

  const draw = (now: number) => {
    gl.uniform1f(u('t'), (still.matches ? 20_000 : now - start) / 1000);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    if (!('ready' in canvas.dataset)) canvas.dataset.ready = '';
  };

  const loop = (now: number) => {
    raf = 0;
    if (now - last >= 33) {
      last = now;
      draw(now);
    }
    if (visible && !still.matches && !document.hidden) raf = requestAnimationFrame(loop);
  };

  const kick = () => {
    if (!raf) raf = requestAnimationFrame(loop);
  };

  const refresh = () => {
    readColors();
    resize();
    draw(performance.now());
    kick();
  };

  new ResizeObserver(() => { resize(); draw(performance.now()); }).observe(hero);
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; kick(); }).observe(hero);
  new MutationObserver(refresh).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'data-os'] });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refresh);
  still.addEventListener('change', refresh);
  document.addEventListener('visibilitychange', kick);
  refresh();
}
