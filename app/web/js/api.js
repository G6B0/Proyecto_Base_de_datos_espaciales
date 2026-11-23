// Acceso a la API y formato de números en español de Chile.

const nf0 = new Intl.NumberFormat('es-CL', { maximumFractionDigits: 0 });
const nf1 = new Intl.NumberFormat('es-CL', { minimumFractionDigits: 1, maximumFractionDigits: 1 });

export const fmt = {
  int: (v) => (v === null || v === undefined ? '—' : nf0.format(v)),
  one: (v) => (v === null || v === undefined ? '—' : nf1.format(v)),
  // 1.348.093 -> "1,35 M"; 79.135 -> "79.135"
  people: (v) => {
    if (v === null || v === undefined) return '—';
    if (v >= 1_000_000) return `${new Intl.NumberFormat('es-CL', { maximumFractionDigits: 2 }).format(v / 1_000_000)} M`;
    return nf0.format(v);
  },
  date: (iso) => {
    const d = new Date(iso);
    const p = (n) => String(n).padStart(2, '0');
    return `${p(d.getUTCDate())}-${p(d.getUTCMonth() + 1)}-${d.getUTCFullYear()} · ${p(d.getUTCHours())}:${p(d.getUTCMinutes())} UTC`;
  },
};

export async function getJSON(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}
