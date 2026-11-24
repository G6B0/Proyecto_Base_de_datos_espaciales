// Deslizador con el estilo del sistema de diseño (pista fina y controles blancos).
// Uno o dos controles; arrastre con puntero y flechas del teclado.
//
//   const r = createRange(el, { min: 0, max: 700, step: 10, values: [0, 700], onInput, onChange });
//   r.values -> [a, b];  r.set([a, b])
//   fill: 'after' (por defecto, "desde el valor") o 'before' ("hasta el valor", para una barra de avance).

export function createRange(container, { min, max, step = 1, values, fill: fillMode = 'after', onInput = () => {}, onChange = () => {} }) {
  container.classList.add('slider-track');
  container.style.cursor = 'pointer';
  container.style.touchAction = 'none';
  container.innerHTML = '';
  const fill = document.createElement('div');
  fill.className = 'slider-fill';
  container.appendChild(fill);

  let current = [...values];
  const thumbs = current.map((_, i) => {
    const thumb = document.createElement('div');
    thumb.className = 'slider-thumb';
    thumb.tabIndex = 0;
    thumb.setAttribute('role', 'slider');
    thumb.setAttribute('aria-valuemin', min);
    thumb.setAttribute('aria-valuemax', max);
    thumb.style.cursor = 'grab';
    // Área de toque más grande que el punto visible.
    thumb.style.boxShadow = '0 0 0 8px rgba(0,0,0,0)';
    container.appendChild(thumb);
    thumb.addEventListener('keydown', (ev) => {
      const delta = { ArrowLeft: -step, ArrowDown: -step, ArrowRight: step, ArrowUp: step }[ev.key];
      if (delta === undefined) return;
      ev.preventDefault();
      setValue(i, current[i] + delta * (ev.shiftKey ? 10 : 1));
      onChange([...current]);
    });
    return thumb;
  });

  const pct = (v) => ((v - min) / (max - min)) * 100;
  const snap = (v) => Math.min(max, Math.max(min, Math.round((v - min) / step) * step + min));

  function render() {
    thumbs.forEach((thumb, i) => {
      thumb.style.left = `${pct(current[i])}%`;
      thumb.setAttribute('aria-valuenow', current[i]);
    });
    if (current.length === 2) {
      fill.style.left = `${pct(current[0])}%`;
      fill.style.right = `${100 - pct(current[1])}%`;
    } else if (fillMode === 'before') {
      fill.style.left = '0%';
      fill.style.right = `${100 - pct(current[0])}%`;
    } else {
      fill.style.left = `${pct(current[0])}%`;
      fill.style.right = '0%';
    }
  }

  function setValue(i, v) {
    let value = snap(v);
    if (current.length === 2) {
      value = i === 0 ? Math.min(value, current[1]) : Math.max(value, current[0]);
    }
    if (value === current[i]) return;
    current[i] = Number(value.toFixed(6));
    render();
    onInput([...current]);
  }

  function valueAt(clientX) {
    const box = container.getBoundingClientRect();
    return min + ((clientX - box.left) / box.width) * (max - min);
  }

  let dragging = null;
  container.addEventListener('pointerdown', (ev) => {
    const v = valueAt(ev.clientX);
    // Mueve el control más cercano al punto de clic.
    dragging = current.length === 2 && Math.abs(v - current[1]) < Math.abs(v - current[0]) ? 1 : 0;
    container.setPointerCapture(ev.pointerId);
    thumbs[dragging].style.cursor = 'grabbing';
    setValue(dragging, v);
  });
  container.addEventListener('pointermove', (ev) => {
    if (dragging !== null) setValue(dragging, valueAt(ev.clientX));
  });
  const end = () => {
    if (dragging === null) return;
    thumbs[dragging].style.cursor = 'grab';
    dragging = null;
    onChange([...current]);
  };
  container.addEventListener('pointerup', end);
  container.addEventListener('pointercancel', end);

  render();
  return {
    get values() { return [...current]; },
    set(newValues) { current = [...newValues]; render(); },
  };
}
