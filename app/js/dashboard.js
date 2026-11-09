// Dashboard para clientes: inversión OOH ejecutada por mercado y vista LATAM de
// proveedores. Replica el dashboard original de OOH LATAM (mismas visuales en
// cada vista y pestaña), pero los datos ya no van dentro del archivo: se piden a
// la base después del login, con tres funciones (fn_dashboard_portada,
// fn_dashboard_mercado, fn_dashboard_latam) que solo devuelven los mercados del
// usuario.
//
// Diferencias deliberadas con el original (aprobadas por Nicolás):
// - Los KPIs del hero no suman monedas locales: van en USD a la tasa vigente,
//   con la nota «USD a TRM del …» debajo (el original sumaba COP+CLP+…).
// - Medio y Ciudad traen los valores reales (en el original venían rotos).
// - La BU (Cliente ML/MP) sale de la columna CLIENTE del Flow.
// - «Datos al …», el corte y las tasas vigentes se muestran, discretos.
// - LATAM también descarga Excel.
//
// Las respuestas se guardan en memoria mientras la página está abierta (objeto
// `cache`), nunca en localStorage, sessionStorage ni en la URL. localStorage
// solo guarda preferencias: idioma y tema.
//
// Va después de config.js y comun.js (de ahí salen `sb`, `requerirAccesoDashboard`
// y `salir`).

// ------------------------------------------------------------------ Constantes

// Quién entra lo decide requerirAccesoDashboard() de comun.js (ROLES_DASHBOARD).
// Quién ve el enlace de vuelta a OASIS. CLIENTE no ve nada de OASIS.
const ROLES_CON_OASIS = ['ADMIN', 'LECTURA', 'ZB'];

// Aviso solo para ADMIN, en la portada y en LATAM. Para mostrar uno:
// AVISO_ADMIN = { es: '…', pt: '…' }. Se usó para avisar que faltaba Mercado
// Pago, cargado el 09-11-2026.
const AVISO_ADMIN = null;

const CLAVE_IDIOMA = 'oasis.dashboard.idioma';
const CLAVE_TEMA = 'oasis.dashboard.tema';

// Banderas por mercado: no son datos, solo presentación. La bandera que manda
// la base tiene prioridad; esta es el respaldo.
const BANDERAS = {
  MCO: '🇨🇴', MLB: '🇧🇷', MLM: '🇲🇽',
  MLA: '🇦🇷', MLC: '🇨🇱', MLU: '🇺🇾',
  MPE: '🇵🇪',
};
// Paletas del original: CL para barras horizontales, TCCL para tipo de costo,
// PCOL y PORD para los países de LATAM (un país nuevo toma un color de CL).
const CL = ['#FDC62C', '#2563EB', '#C2410C', '#3F6B3F', '#9333EA', '#EA580C', '#0891B2', '#DB2777', '#65A30D', '#6366F1'];
const TCCL = ['#E65100', '#00695C', '#4527A0', '#AD1457', '#0277BD', '#558B2F', '#6A1B9A', '#BF360C', '#1B5E20', '#4E342E'];
const PCOL = { ARGENTINA: '#42A5F5', CHILE: '#D32F2F', COLOMBIA: '#F9A825', MEXICO: '#2E7D32', URUGUAY: '#1565C0' };
const PORD = ['ARGENTINA', 'CHILE', 'COLOMBIA', 'MEXICO', 'URUGUAY'];

// ------------------------------------------------------------------ Textos (ES / PT)

const T = {
  es: {
    dashReg: 'Dashboard Regional', heroSub: 'Inversión OOH — Costo Ejecutado Acumulado por Mercado',
    paises: 'Países', anio: 'Año', selMerc: 'Selecciona un mercado',
    filtros: 'Filtros', limpiar: 'limpiar', todo: 'todo', limpiarAll: 'Limpiar filtros',
    fk: [['cli', 'Cliente'], ['m', 'Mes'], ['camp', 'Campaña'], ['sub', 'Subcampaña'], ['tc', 'Tipo de Costo'], ['prov', 'Proveedor'], ['fmt', 'Formato'], ['med', 'Medio'], ['city', 'Ciudad']],
    tabs: [['monthly', 'Inv. Mensual'], ['weekly', 'Inv. Semanal'], ['subcampana', 'Subcampañas'], ['costos', 'Tipo de Costos'], ['proveedores', 'Proveedores'], ['campanas', 'Campañas']],
    inv: 'Inversión', provs: 'Proveedores', fmts: 'Formatos', cities: 'Ciudades',
    mn: ['', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'],
    invMensual: 'Inversión <em>Mensual</em>', detMensual: 'Detalle <em>Mensual</em>',
    invSemanal: 'Inversión <em>Semanal</em>', detSemanal: 'Detalle <em>Semanal</em>',
    invSub: 'Inversión por <em>Subcampaña</em>', detSub: 'Detalle <em>Subcampaña</em>',
    distTC: 'Distribución por <em>Tipo de Costo</em>', costXSub: 'Costo por <em>Subcampaña</em>',
    mixProv: 'Mix de <em>Proveedores</em>', detProv: 'Detalle <em>Proveedores</em>',
    invCamp: 'Inversión por <em>Campaña</em>', campXMes: 'Campaña × <em>Mes</em>', campXTC: 'Campaña × <em>Tipo de Costo</em>', campana: 'Campaña',
    nombre: 'Nombre', costoEj: 'Costo Ejecutado', share: 'Share', mes: 'Mes', semana: 'Semana', total: 'Total', sub: 'Sub',
    pfLabel: 'OOH', campLabel: 'Campañas',
    // Propios de OASIS
    datosAl: 'Datos al', corte: 'Corte', moneda: 'Moneda', monedaLocal: 'Moneda Local', pais: 'País', tipoCosto: 'Tipo de Costo', cliente: 'Cliente', proveedor: 'Proveedor',
    cargando: 'Cargando…', errCarga: 'No se pudo cargar la información', reintentar: 'Reintentar',
    sinAcceso: 'No tienes acceso a estos datos.', sesionVencida: 'Tu sesión venció. Vuelve a entrar.',
    salir: 'Cerrar sesión', temaClaro: 'Cambiar a tema claro', temaOscuro: 'Cambiar a tema oscuro',
    sinDatosAnio: 'No hay inversión ejecutada en {a} en tus mercados.', sinFilas: 'No hay datos con estos filtros.',
    activos: 'activos',
    latamCode: 'Consolidado — USD', latamSub: 'Visión para Compras',
    provPais: 'Inversión por <em>Proveedor</em> — Share por País', detPais: 'Detalle por País',
    provTC: 'Inversión por <em>Proveedor</em> — Share por Tipo de Costo',
    tasa: 'USD a TRM {v} · vigente desde {d}', notaTrm: 'USD a TRM del {d}',
    sinTasa: 'sin tasa de cambio: no entra en los totales en USD',
    invLocal: 'Inversión (moneda local)',
    xls: ['Mes', 'Semana', 'Proveedor', 'Tipo de Costo', 'Formato', 'Campaña', 'Subcampaña', 'Costo Ejecutado', 'Cliente', 'Medio', 'Ciudad', 'Moneda'],
  },
  pt: {
    dashReg: 'Dashboard Regional', heroSub: 'Investimento OOH — Custo Executado Acumulado por Mercado',
    paises: 'Países', anio: 'Ano', selMerc: 'Selecione um mercado',
    filtros: 'Filtros', limpiar: 'limpar', todo: 'todos', limpiarAll: 'Limpar filtros',
    fk: [['cli', 'Unidade de Negócio'], ['m', 'Mês'], ['camp', 'Campanha'], ['sub', 'Subcampanha'], ['tc', 'Tipo de Custo'], ['prov', 'Fornecedor'], ['fmt', 'Formato'], ['med', 'Meio'], ['city', 'Cidade']],
    tabs: [['monthly', 'Inv. Mensal'], ['weekly', 'Inv. Semanal'], ['subcampana', 'Subcampanhas'], ['costos', 'Tipo de Custos'], ['proveedores', 'Fornecedores'], ['campanas', 'Campanhas']],
    inv: 'Investimento', provs: 'Fornecedores', fmts: 'Formatos', cities: 'Cidades',
    mn: ['', 'Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez'],
    invMensual: 'Investimento <em>Mensal</em>', detMensual: 'Detalhe <em>Mensal</em>',
    invSemanal: 'Investimento <em>Semanal</em>', detSemanal: 'Detalhe <em>Semanal</em>',
    invSub: 'Investimento por <em>Subcampanha</em>', detSub: 'Detalhe <em>Subcampanha</em>',
    distTC: 'Distribuição por <em>Tipo de Custo</em>', costXSub: 'Custo por <em>Subcampanha</em>',
    mixProv: 'Mix de <em>Fornecedores</em>', detProv: 'Detalhe <em>Fornecedores</em>',
    invCamp: 'Investimento por <em>Campanha</em>', campXMes: 'Campanha × <em>Mês</em>', campXTC: 'Campanha × <em>Tipo de Custo</em>', campana: 'Campanha',
    nombre: 'Nome', costoEj: 'Custo Executado', share: 'Share', mes: 'Mês', semana: 'Semana', total: 'Total', sub: 'Sub',
    pfLabel: 'OOH', campLabel: 'Campanhas',
    datosAl: 'Dados de', corte: 'Corte', moneda: 'Moeda', monedaLocal: 'Moeda Local', pais: 'País', tipoCosto: 'Tipo de Custo', cliente: 'Unidade de Negócio', proveedor: 'Fornecedor',
    cargando: 'Carregando…', errCarga: 'Não foi possível carregar as informações', reintentar: 'Tentar de novo',
    sinAcceso: 'Você não tem acesso a estes dados.', sesionVencida: 'Sua sessão expirou. Entre novamente.',
    salir: 'Sair', temaClaro: 'Mudar para tema claro', temaOscuro: 'Mudar para tema escuro',
    sinDatosAnio: 'Não há investimento executado em {a} nos seus mercados.', sinFilas: 'Não há dados com estes filtros.',
    activos: 'ativos',
    latamCode: 'Consolidado — USD', latamSub: 'Visão para Compras',
    provPais: 'Investimento por <em>Fornecedor</em> — Share por País', detPais: 'Detalhe por País',
    provTC: 'Investimento por <em>Fornecedor</em> — Share por Tipo de Custo',
    tasa: 'USD a TRM {v} · vigente desde {d}', notaTrm: 'USD a TRM de {d}',
    sinTasa: 'sem taxa de câmbio: não entra nos totais em USD',
    invLocal: 'Investimento (moeda local)',
    xls: ['Mês', 'Semana', 'Fornecedor', 'Tipo de Custo', 'Formato', 'Campanha', 'Subcampanha', 'Custo Executado', 'Unidade de Negócio', 'Meio', 'Cidade', 'Moeda'],
  },
};
function t(k) { return T[lang][k] !== undefined ? T[lang][k] : k; }

// ------------------------------------------------------------------ Estado

let lang = 'es';
let usuario = null;          // { rol, nombre }
const ANIO_ACTUAL = new Date().getFullYear();
let anio = ANIO_ACTUAL;
let vista = { tipo: 'portada' };   // { tipo: 'portada' | 'mercado' | 'latam', codigo }
let cache = {};              // respuestas de la base, solo en memoria
let turno = 0;               // descarta respuestas que llegan tarde
let af = {};                 // filtros activos: { clave: { valor: true } }
let cs = 'monthly';          // pestaña activa del mercado
let lusd = false;            // LATAM en USD
let actual = null;           // datos de la vista en pantalla

// ------------------------------------------------------------------ Utilidades

const $$ = (id) => document.getElementById(id);

// Todo texto que viene de los datos (nombres de los Sheets) pasa por aquí antes
// de ir a innerHTML.
function esc(v) {
  return String(v == null ? '' : v).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function fn(v) { return Number(v || 0).toLocaleString('es-CO', { maximumFractionDigits: 0 }); }
function fp(v) { return (isFinite(v) ? v : 0).toFixed(1) + '%'; }

// Monto abreviado con su moneda: COP 1.234MM, COP 12.3M, COP 4.5K.
function fc(v, moneda) {
  v = Number(v || 0);
  const a = Math.abs(v), u = moneda ? moneda + ' ' : '';
  if (a >= 1e9) return u + fn(Math.round(v / 1e6)) + 'MM';
  if (a >= 1e6) return u + (v / 1e6).toFixed(1) + 'M';
  if (a >= 1e3) return u + (v / 1e3).toFixed(1) + 'K';
  return u + Math.round(v);
}
function fusd(v) {
  v = Number(v || 0);
  const a = Math.abs(v);
  if (a >= 1e6) return 'USD ' + (v / 1e6).toFixed(2) + 'M';
  if (a >= 1e3) return 'USD ' + (v / 1e3).toFixed(1) + 'K';
  return 'USD ' + Math.round(v);
}

// dd/mm/aaaa hh:mm en hora local.
function fechaHora(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  if (isNaN(d)) return '—';
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
// 'aaaa-mm-dd' → dd/mm/aaaa, sin pasar por Date (evita correrse un día por zona horaria).
function fecha(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s || '');
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '—';
}

function bandera(codigo, deLaBase) { return deLaBase || BANDERAS[codigo] || '🌎'; }
const vacioTxt = (v) => v == null || v === '' || v === '—';

function leerPref(clave) { try { return localStorage.getItem(clave); } catch { return null; } }
function guardarPref(clave, valor) { try { localStorage.setItem(clave, valor); } catch { /* sin almacenamiento */ } }

// ------------------------------------------------------------------ Arranque y acceso

async function iniciar() {
  // Sin sesión, al login (que vuelve aquí); clave temporal, externos y roles sin
  // dashboard, a su página. La protección real está en la base (42501).
  usuario = await requerirAccesoDashboard();

  sb.auth.onAuthStateChange((evento) => { if (evento === 'SIGNED_OUT') location.replace('index.html'); });
  $$('oasisLink').classList.toggle('hidden', !ROLES_CON_OASIS.includes(usuario.rol));

  const inicial = vistaDeHash();
  history.replaceState(inicial, '', hashDe(inicial));
  mostrar(inicial, false);
}

// La vista (no los datos) va en el hash para que el botón «atrás» funcione.
function hashDe(v) {
  if (v.tipo === 'mercado') return '#' + v.codigo;
  if (v.tipo === 'latam') return '#latam';
  return location.pathname + location.search;
}
function vistaDeHash() {
  const h = decodeURIComponent(location.hash.slice(1));
  if (h === 'latam') return { tipo: 'latam' };
  if (/^[A-Z]{3}$/.test(h)) return { tipo: 'mercado', codigo: h };
  return { tipo: 'portada' };
}
window.addEventListener('popstate', (e) => {
  if (usuario) mostrar(e.state || vistaDeHash(), false);
});

// ------------------------------------------------------------------ Carga de datos

async function pedir(clave, funcion, params, preparar) {
  if (cache[clave]) return cache[clave];
  const { data, error } = await sb.rpc(funcion, params);
  if (error) throw error;
  cache[clave] = preparar ? preparar(data) : data;
  return cache[clave];
}

function cargando() {
  $$('home').classList.add('hidden');
  $$('detail').classList.add('hidden');
  $$('estado').innerHTML = `<div class="caja"><span class="giro" aria-hidden="true"></span><span>${esc(t('cargando'))}</span></div>`;
}

function mostrarError(e, reintento) {
  console.error(e);
  $$('home').classList.add('hidden');
  $$('detail').classList.add('hidden');
  $$('dlBtn').classList.add('hidden');
  const msg = String((e && e.message) || e || '');
  let titulo = t('errCarga'), detalle = msg;
  if (e && e.code === '42501') { titulo = t('sinAcceso'); detalle = ''; }
  else if ((e && e.code === 'PGRST301') || /jwt/i.test(msg)) { titulo = t('sesionVencida'); detalle = ''; }
  $$('estado').innerHTML = `<div class="caja error" role="alert"><div style="flex:1;min-width:200px"><b></b><span></span></div>
    <button class="reintentar" type="button">${esc(t('reintentar'))}</button></div>`;
  $$('estado').querySelector('b').textContent = titulo;
  $$('estado').querySelector('span').textContent = detalle;
  $$('estado').querySelector('.reintentar').addEventListener('click', reintento || (() => mostrar(vista, false)));
}

// Muestra una vista: pide lo que falte y pinta. `empujar` = agregar al historial.
async function mostrar(v, empujar = true) {
  const cambia = v.tipo !== vista.tipo || v.codigo !== vista.codigo;
  vista = v;
  if (empujar) history.pushState(v, '', hashDe(v));
  const mio = ++turno;
  pintarBarra();
  const clave = v.tipo === 'mercado' ? `m:${v.codigo}:${anio}` : `${v.tipo}:${anio}`;
  if (!cache[clave]) cargando();
  try {
    let d;
    if (v.tipo === 'portada') d = await pedir(clave, 'fn_dashboard_portada', { p_anio: anio });
    else if (v.tipo === 'mercado') d = await pedir(clave, 'fn_dashboard_mercado', { p_mercado: v.codigo, p_anio: anio }, prepararMercado);
    else d = await pedir(clave, 'fn_dashboard_latam', { p_anio: anio }, prepararLatam);
    if (mio !== turno) return;
    $$('estado').innerHTML = '';
    actual = d;
    if (v.tipo === 'portada') pintarPortada(d);
    else if (v.tipo === 'mercado') pintarMercado(d, cambia);
    else pintarLatam(d, cambia);
  } catch (e) {
    if (mio !== turno) return;
    mostrarError(e);
  }
}

// ------------------------------------------------------------------ Barra superior

function pintarBarra() {
  const enPortada = vista.tipo === 'portada';
  $$('bbw').classList.toggle('hidden', enPortada);
  $$('btnVolver').textContent = '◀ LATAM';   // como el original: volver a la portada
  $$('salirBtn').textContent = t('salir');
  $$('lES').classList.toggle('on', lang === 'es');
  $$('lPT').classList.toggle('on', lang === 'pt');
  $$('anioSel').setAttribute('aria-label', t('anio'));
  $$('dlBtn').classList.toggle('hidden', enPortada);
  pintarBotonTema();
  if (enPortada) $$('crumb').textContent = t('dashReg');
  else if (vista.tipo === 'latam') $$('crumb').innerHTML = '🌎 <b>LATAM</b> — ' + esc(t('provs'));
  else if (!actual || actual.codigo !== vista.codigo) $$('crumb').textContent = vista.codigo;
}

function llenarAnios() {
  const sel = $$('anioSel');
  sel.innerHTML = [0, 1, 2].map((i) => `<option value="${ANIO_ACTUAL - i}">${ANIO_ACTUAL - i}</option>`).join('');
  sel.value = String(anio);
  sel.addEventListener('change', () => {
    anio = Number(sel.value);
    cache = {};            // otro año: todo se vuelve a pedir
    af = {};               // los valores de los filtros cambian con el año
    mostrar(vista, false);
  });
}

function temaEfectivo() {
  const fijo = document.documentElement.getAttribute('data-theme');
  if (fijo) return fijo;
  return window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function pintarBotonTema() {
  const oscuro = temaEfectivo() === 'dark';
  const b = $$('temaBtn');
  b.textContent = oscuro ? '☀' : '☾';
  b.title = oscuro ? t('temaClaro') : t('temaOscuro');
  b.setAttribute('aria-label', b.title);
}

function setLang(l) {
  lang = l;
  guardarPref(CLAVE_IDIOMA, l);
  document.documentElement.lang = l === 'pt' ? 'pt' : 'es';
  // Vuelve a pintar desde la memoria, sin pedir nada y sin perder filtros.
  if (usuario) mostrar(vista, false);
}

// ------------------------------------------------------------------ Aviso para ADMIN

function avisoAdmin() {
  if (!AVISO_ADMIN || !usuario || usuario.rol !== 'ADMIN') return '';
  return `<div class="aviso" role="note">${esc(AVISO_ADMIN[lang])}</div>`;
}

// ------------------------------------------------------------------ Portada

function pintarPortada(d) {
  $$('detail').classList.add('hidden');
  $$('home').classList.remove('hidden');
  const mercados = (d && d.mercados) || [];
  $$('heroAnio').textContent = (d && d.anio) || anio;
  $$('heroSub').textContent = t('heroSub');
  $$('selTitle').textContent = t('selMerc');

  // Mismas celdas que el original (Países, OOH, Campañas, Año), pero los montos
  // regionales van en USD a la tasa vigente: nunca se suman monedas locales.
  const tasaDe = {};
  for (const x of ((d && d.tasas) || [])) tasaDe[x.mercado] = x;
  let usdPf = 0, usdCi = 0, vigente = '', conTasa = 0;
  const sinTasa = [];
  for (const m of mercados) {
    const ta = tasaDe[m.codigo], v = ta && Number(ta.valor_por_usd);
    if (!(v > 0)) { sinTasa.push(m); continue; }
    usdPf += Number(m.pf || 0) / v;
    usdCi += Number(m.ci || 0) / v;
    if (String(ta.vigente_desde || '') > vigente) vigente = String(ta.vigente_desde);
    conTasa++;
  }
  $$('hkpis').innerHTML =
    `<div><div class="k">${esc(t('paises'))}</div><div class="v">${mercados.length}</div></div>` +
    `<div><div class="k">${esc(t('pfLabel'))}</div><div class="v" style="font-size:16px">${conTasa ? esc(fusd(usdPf)) : '—'}</div></div>` +
    `<div><div class="k">${esc(t('campLabel'))}</div><div class="v" style="font-size:16px">${conTasa ? esc(fusd(usdCi)) : '—'}</div></div>` +
    `<div><div class="k">${esc(t('anio'))}</div><div class="v">${esc((d && d.anio) || anio)}</div></div>`;

  // Nota discreta: fecha de los datos y tasa usada; mercados sin tasa, avisados.
  let nota = `<span>${esc(t('datosAl'))} ${esc(fechaHora(d && d.ultima_carga))}` +
    (conTasa && vigente ? ` · ${esc(t('notaTrm').replace('{d}', fecha(vigente)))}` : '') + '</span>';
  for (const m of sinTasa) nota += `<span class="falta">${esc(bandera(m.codigo, m.bandera))} ${esc(m.codigo)}: ${esc(t('sinTasa'))}</span>`;
  $$('notaHome').innerHTML = nota;
  $$('avisoHome').innerHTML = avisoAdmin();

  const g = $$('cgrid');
  g.innerHTML = '';
  if (!mercados.length) {
    g.innerHTML = `<div class="vacio">${esc(t('sinDatosAnio').replace('{a}', anio))}</div>`;
    return;
  }
  for (const m of mercados) {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'ccard';
    el.innerHTML =
      `<div class="cflag">${esc(bandera(m.codigo, m.bandera))}</div>` +
      `<div class="cname">${esc(m.nombre)}</div>` +
      `<div class="ccode">${esc(m.codigo)} — ${esc(m.moneda)}</div>` +
      `<div class="cinv">${esc(fc(m.t, m.moneda))}</div>` +
      `<div class="cpf"><span class="lbl">${esc(t('pfLabel'))}</span><span class="val">${esc(fc(m.pf, m.moneda))}</span></div>` +
      (Number(m.ci) ? `<div class="ccmp"><span class="lbl">${esc(t('campLabel'))}</span><span class="val">${esc(fc(m.ci, m.moneda))}</span></div>` : '') +
      `<div class="carrow">▶</div>`;
    el.addEventListener('click', () => mostrar({ tipo: 'mercado', codigo: m.codigo }));
    g.appendChild(el);
  }

  // LATAM solo tiene sentido con más de un mercado.
  if (mercados.length > 1) {
    const lc = document.createElement('button');
    lc.type = 'button';
    lc.className = 'ccard latam';
    lc.innerHTML = `<div class="cflag">🌎</div><div class="cname">LATAM</div>` +
      `<div class="ccode">${esc(t('latamCode'))}</div><div class="cinv">${esc(t('provs'))}</div>` +
      `<div class="csop">${esc(t('latamSub'))}</div><div class="carrow">▶</div>`;
    lc.addEventListener('click', () => mostrar({ tipo: 'latam' }));
    g.appendChild(lc);
  }
}

// ------------------------------------------------------------------ Mercado

// Las filas llegan agrupadas y con los textos como índices en `s`.
// [mes, semana, prov, tipo_costo, formato, campana, subcampana, costo, bu, medio, ciudad]
function prepararMercado(d) {
  const s = (d && d.s) || [];
  const txt = (i) => {
    const v = typeof i === 'number' ? s[i] : i;
    return vacioTxt(v) ? '—' : String(v);
  };
  d.rows = ((d && d.r) || []).map((r) => ({
    m: Number(r[0]) || 0, w: Number(r[1]) || 0,
    prov: txt(r[2]), tc: txt(r[3]), fmt: txt(r[4]), camp: txt(r[5]), sub: txt(r[6]),
    cost: Number(r[7]) || 0, cli: txt(r[8]), med: txt(r[9]), city: txt(r[10]),
  }));
  return d;
}

function pintarMercado(d, reiniciar) {
  if (reiniciar) { af = {}; cs = 'monthly'; }
  $$('home').classList.add('hidden');
  $$('detail').classList.remove('hidden');
  $$('crumb').innerHTML = `${esc(bandera(d.codigo, d.f))} <b>${esc(d.n)}</b> — ${esc(d.codigo)}`;
  $$('avisoDet').innerHTML = '';
  $$('nota').classList.add('hidden');
  $$('meta').innerHTML =
    `<span>${esc(t('datosAl'))} <b>${esc(fechaHora(d.ultima_carga))}</b></span>` +
    `<span>${esc(t('corte'))} <b>${esc(fecha(d.corte))}</b></span>` +
    `<span>${esc(t('moneda'))} <b>${esc(d.c)}</b></span>`;
  $$('filtTitle').textContent = t('filtros');
  $$('clrAllBtn').textContent = t('limpiarAll');
  $$('clrAllBtn').onclick = () => { af = {}; sF(); upd(); };
  bldF(d.rows, t('fk'), upd);
  bldT();
  upd();
}

// Filtros de la barra lateral. Una clave con menos de dos valores no se muestra
// (salvo Mes y Cliente, como en el original).
function bldF(rows, fks, alCambiar, opciones = {}) {
  const ct = $$('fg');
  ct.innerHTML = '';
  if (opciones.antes) ct.appendChild(opciones.antes);
  const mn = t('mn');
  for (const [k, label] of fks) {
    const uv = new Set();
    for (const r of rows) {
      const v = r[k];
      if (k === 'm' || k === 'mes') { if (v > 0) uv.add(v); } else if (v != null && String(v).trim()) uv.add(v);
    }
    const esMes = k === 'm' || k === 'mes';
    // Orden ASCII plano, como el original (la ñ y los símbolos van al final).
    const vals = esMes ? [...uv].map(Number).sort((a, b) => a - b) : [...uv].sort();
    if (vals.length < 2 && !esMes && k !== 'cli') continue;

    const gr = document.createElement('div');
    gr.className = 'fgrp';
    gr.dataset.fk = k;
    const hdr = document.createElement('div');
    hdr.className = 'fl';
    hdr.appendChild(document.createTextNode(label));
    const ac = document.createElement('span');
    ac.className = 'fac';
    const allBtn = document.createElement('button');
    allBtn.type = 'button'; allBtn.className = 'fall'; allBtn.textContent = t('todo');
    allBtn.addEventListener('click', () => { af[k] = {}; for (const v of vals) af[k][String(v)] = true; sF(); alCambiar(); });
    const clr = document.createElement('button');
    clr.type = 'button'; clr.className = 'fclr'; clr.textContent = t('limpiar');
    clr.addEventListener('click', () => { delete af[k]; sF(); alCambiar(); });
    ac.appendChild(allBtn); ac.appendChild(clr); hdr.appendChild(ac); gr.appendChild(hdr);

    const opts = document.createElement('div');
    opts.className = 'fopts';
    for (const v of vals) {
      const lb = document.createElement('label');
      lb.className = 'fopt';
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.value = String(v);
      cb.addEventListener('change', () => {
        if (!af[k]) af[k] = {};
        if (cb.checked) af[k][String(v)] = true; else delete af[k][String(v)];
        if (!Object.keys(af[k]).length) delete af[k];
        sF(); alCambiar();
      });
      lb.appendChild(cb);
      const etiqueta = esMes ? mn[v] : v;
      lb.appendChild(document.createTextNode(' ' + etiqueta));
      opts.appendChild(lb);
    }
    gr.appendChild(opts);
    ct.appendChild(gr);
  }
  sF();
}

// Marca las casillas según `af` y actualiza el botón de filtros del celular.
function sF() {
  for (const gr of document.querySelectorAll('#fg .fgrp[data-fk]')) {
    const fk = gr.dataset.fk;
    for (const cb of gr.querySelectorAll('.fopt input[type=checkbox]')) {
      const on = !!(af[fk] && af[fk][cb.value]);
      cb.checked = on;
      cb.closest('.fopt').classList.toggle('on', on);
    }
  }
  const n = Object.keys(af).length;
  $$('fToggle').innerHTML = `<span>${esc(t('filtros'))}${n ? ` · ${n} ${esc(t('activos'))}` : ''}</span><span aria-hidden="true">${$$('side').classList.contains('abierto') ? '▴' : '▾'}</span>`;
}

function pasaFiltros(r) {
  for (const fk of Object.keys(af)) {
    const vs = af[fk];
    if (!vs) continue;
    if (!vs[String(r[fk])]) return false;
  }
  return true;
}

function gfr() { return actual.rows.filter((r) => pasaFiltros(r)); }

function bldT() {
  const el = $$('tabs');
  el.innerHTML = '';
  for (const [tid, lbl] of t('tabs')) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'tab' + (tid === cs ? ' on' : '');
    b.textContent = lbl;
    b.addEventListener('click', () => {
      cs = tid;
      for (const x of el.querySelectorAll('.tab')) x.classList.remove('on');
      b.classList.add('on');
      ren(gfr());
    });
    el.appendChild(b);
  }
}

function upd() {
  const recs = gfr(), cur = actual.c;
  let ti = 0;
  const pv = new Set(), fm = new Set(), ci = new Set();
  for (const r of recs) {
    ti += r.cost;
    if (!vacioTxt(r.prov)) pv.add(r.prov);
    if (!vacioTxt(r.fmt)) fm.add(r.fmt);
    if (!vacioTxt(r.city)) ci.add(r.city);
  }
  $$('kpis').innerHTML =
    `<div class="mkpi hl"><div class="kl">${esc(t('inv'))}</div><div class="kv">${esc(fc(ti, cur))}</div></div>` +
    `<div class="mkpi"><div class="kl">${esc(t('provs'))}</div><div class="kv">${pv.size}</div></div>` +
    `<div class="mkpi"><div class="kl">${esc(t('fmts'))}</div><div class="kv">${fm.size}</div></div>` +
    `<div class="mkpi"><div class="kl">${esc(t('cities'))}</div><div class="kv">${ci.size}</div></div>`;
  ren(recs);
}

function sumarPor(recs, clave) {
  const o = {};
  for (const r of recs) o[r[clave]] = (o[r[clave]] || 0) + r.cost;
  return o;
}

function ren(recs) {
  const el = $$('out'), mn = t('mn'), cur = actual.c;
  el.innerHTML = '';
  if (!recs.length) { el.innerHTML = `<div class="vacio">${esc(t('sinFilas'))}</div>`; return; }

  if (cs === 'monthly' || cs === 'weekly') {
    const semanal = cs === 'weekly', clave = semanal ? 'w' : 'm';
    const b = {};
    for (const r of recs) if (r[clave] > 0) b[r[clave]] = (b[r[clave]] || 0) + r.cost;
    const etq = semanal ? (k) => 'W' + k : (k) => mn[k];
    bar(b, el, t(semanal ? 'invSemanal' : 'invMensual'), etq, semanal, cur);
    const ks = Object.keys(b).map(Number).sort((a, c) => a - c);
    const tot = ks.reduce((s, k) => s + b[k], 0);
    let s = `<h4>${t(semanal ? 'detSemanal' : 'detMensual')}</h4><div class="tscroll"><table class="dt"><thead><tr><th>${esc(t(semanal ? 'semana' : 'mes'))}</th><th class="num">${esc(t('costoEj'))}</th><th class="num">${esc(t('share'))}</th></tr></thead><tbody>`;
    for (const k of ks) s += `<tr><td>${esc(etq(k))}</td><td class="num">${fn(Math.round(b[k]))}</td><td class="num">${fp(tot > 0 ? b[k] / tot * 100 : 0)}</td></tr>`;
    s += `<tr class="tot"><td>${esc(t('total'))}</td><td class="num">${fn(Math.round(tot))}</td><td class="num">100.0%</td></tr></tbody></table></div>`;
    panel(el, s);
  } else if (cs === 'subcampana') {
    const bs = sumarPor(recs, 'sub');
    hbar(el, t('invSub'), bs, cur); tbl(el, t('detSub'), bs, cur);
  } else if (cs === 'costos') {
    const bt = sumarPor(recs, 'tc');
    hbar(el, t('distTC'), bt, cur);
    xtab(el, t('costXSub'), recs, 'sub', 'tc', (k) => k, cur, false, t('sub'));
  } else if (cs === 'proveedores') {
    const bp = sumarPor(recs, 'prov');
    hbar(el, t('mixProv'), bp, cur); tbl(el, t('detProv'), bp, cur);
  } else if (cs === 'campanas') {
    hbar(el, t('invCamp'), sumarPor(recs, 'camp'), cur);
    xtab(el, t('campXMes'), recs.filter((r) => r.m > 0), 'camp', 'm', (k) => mn[k], cur, true, t('campana'));
    xtab(el, t('campXTC'), recs, 'camp', 'tc', (k) => k, cur, true, t('campana'));
  }
}

function panel(el, html) {
  const w = document.createElement('div');
  w.className = 'panel';
  w.innerHTML = html;
  el.appendChild(w);
  return w;
}

// Barras verticales (mes o semana). `titulo` es texto propio, con <em>.
function bar(data, el, titulo, lblFn, azul, cur) {
  const ks = Object.keys(data).map(Number).sort((a, b) => a - b);
  let mx = 0;
  for (const k of ks) if (data[k] > mx) mx = data[k];
  if (mx <= 0) mx = 1;
  const w = panel(el, `<h4>${titulo}</h4>`);
  const ch = document.createElement('div');
  ch.className = 'bchart' + (azul ? ' wchart' : '');
  for (const k of ks) {
    const v = data[k], pct = (Math.max(v, 0) / mx * 80) + 5;
    const c = document.createElement('div');
    c.className = 'bcol';
    c.innerHTML = `<div class="bval">${esc(fc(v, cur))}</div><div class="bbar${azul ? ' blue' : ''}" style="height:${pct}%"></div><div class="blbl">${esc(lblFn(k))}</div>`;
    ch.appendChild(c);
  }
  // Como el original: con más de 12 barras (la semanal) van en una franja con
  // scroll propio y flechas; con 12 o menos, las barras se reparten el ancho.
  if (ks.length > 12) {
    const sw = document.createElement('div'); sw.className = 'scroll-wrap';
    const si = document.createElement('div'); si.className = 'scroll-inner';
    si.appendChild(ch);
    const al = document.createElement('button'); al.type = 'button'; al.className = 'sarrow left'; al.innerHTML = '&#9664;';
    al.addEventListener('click', () => { si.scrollLeft -= 300; });
    const ar = document.createElement('button'); ar.type = 'button'; ar.className = 'sarrow right'; ar.innerHTML = '&#9654;';
    ar.addEventListener('click', () => { si.scrollLeft += 300; });
    sw.appendChild(al); sw.appendChild(si); sw.appendChild(ar);
    w.appendChild(sw);
  } else w.appendChild(ch);
}

function ordenarDesc(obj) { return Object.entries(obj).sort((a, b) => b[1] - a[1]); }

// Barras horizontales con share.
function hbar(el, titulo, obj, cur) {
  const arr = ordenarDesc(obj);
  let tot = 0, mx = 0;
  for (const [, v] of arr) { tot += v; if (v > mx) mx = v; }
  if (mx <= 0) mx = 1;
  let s = `<h4>${titulo}</h4><div class="hbars">`;
  arr.forEach(([k, v], i) => {
    const pct = Math.max(v, 0) / mx * 100, sh = tot > 0 ? v / tot * 100 : 0, valTxt = esc(fc(v, cur)), dentro = pct > 25;
    s += `<div class="hbar-row"><div class="hbar-name" title="${esc(k)}">${esc(k)}</div><div class="hbar-track">` +
      `<div class="hbar-fill" style="width:${pct}%;background:${CL[i % CL.length]}">${dentro ? valTxt : ''}</div>` +
      (dentro ? '' : `<span class="hbar-out" style="left:${pct + 1}%">${valTxt}</span>`) +
      `</div><div class="hbar-pct">${fp(sh)}</div></div>`;
  });
  panel(el, s + '</div>');
}

function tbl(el, titulo, obj, cur) {
  const arr = ordenarDesc(obj);
  const tot = arr.reduce((s, [, v]) => s + v, 0);
  let s = `<h4>${titulo}</h4><div class="tscroll"><table class="dt"><thead><tr><th>${esc(t('nombre'))}</th><th class="num">${esc(t('inv'))}</th><th class="num">${esc(t('share'))}</th><th style="width:80px"></th></tr></thead><tbody>`;
  for (const [k, v] of arr) {
    const sh = tot > 0 ? v / tot * 100 : 0;
    s += `<tr><td>${esc(k)}</td><td class="num">${esc(fc(v, cur))}</td><td class="num">${fp(sh)}</td><td><div class="sbar"><div class="sfill" style="width:${Math.max(sh, 0)}%"></div></div></td></tr>`;
  }
  s += `<tr class="tot"><td>${esc(t('total'))}</td><td class="num">${fn(Math.round(tot))}</td><td class="num">100.0%</td><td></td></tr></tbody></table></div>`;
  panel(el, s);
}

// Tabla cruzada: filas por `fila`, columnas por `col`, total y (opcional) share.
function xtab(el, titulo, recs, fila, col, colLbl, cur, conShare, cabFila) {
  const m = {}, cols = new Set();
  for (const r of recs) {
    const f = r[fila], c = r[col];
    if (!m[f]) m[f] = {};
    m[f][c] = (m[f][c] || 0) + r.cost;
    cols.add(c);
  }
  const cks = col === 'm' ? [...cols].sort((a, b) => a - b) : [...cols].sort();
  const fks = Object.keys(m).sort();
  const totFila = {};
  let gt = 0;
  for (const f of fks) { totFila[f] = cks.reduce((s, c) => s + (m[f][c] || 0), 0); gt += totFila[f]; }
  let s = `<h4>${titulo}</h4><div class="tscroll"><table class="dt"><thead><tr><th>${esc(cabFila)}</th>`;
  for (const c of cks) s += `<th class="num">${esc(colLbl(c))}</th>`;
  s += `<th class="num">${esc(t('total'))}</th>${conShare ? `<th class="num">${esc(t('share'))}</th>` : ''}</tr></thead><tbody>`;
  const totCol = {};
  for (const f of fks) {
    s += `<tr><td>${esc(f)}</td>`;
    for (const c of cks) {
      const v = m[f][c] || 0;
      totCol[c] = (totCol[c] || 0) + v;
      s += `<td class="num">${v ? esc(fc(v, cur)) : '—'}</td>`;
    }
    s += `<td class="num" style="font-weight:700">${esc(fc(totFila[f], cur))}</td>${conShare ? `<td class="num">${fp(gt > 0 ? totFila[f] / gt * 100 : 0)}</td>` : ''}</tr>`;
  }
  s += `<tr class="tot"><td>${esc(t('total'))}</td>`;
  for (const c of cks) s += `<td class="num">${fn(Math.round(totCol[c] || 0))}</td>`;
  s += `<td class="num">${fn(Math.round(gt))}</td>${conShare ? '<td class="num">100.0%</td>' : ''}</tr></tbody></table></div>`;
  panel(el, s);
}

// ------------------------------------------------------------------ LATAM
// Las tres secciones son las mismas en moneda local y en USD, como en el
// original: las barras apiladas y los totales por proveedor van SIEMPRE en USD
// (la escala común); en moneda local solo cambian las celdas por país de la
// tabla, cada una en su moneda. Nunca se suman monedas locales entre países.

// El original escribe los países en mayúsculas y sin tildes (ARGENTINA,
// MEXICO); la base los manda capitalizados (Argentina, México). Se normalizan
// al entrar para que los colores (PCOL), el orden (PORD) y la vista queden
// idénticos al original.
function paisTxt(v) {
  return String(v || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().trim();
}

function prepararLatam(d) {
  d.rows = ((d && d.filas) || []).map((f) => ({
    prov: vacioTxt(f.prov) ? '—' : String(f.prov),
    tc: vacioTxt(f.tc) ? '—' : String(f.tc),
    cli: vacioTxt(f.cli) ? '—' : String(f.cli),
    mes: Number(f.mes) || 0,
    pais: paisTxt(vacioTxt(f.pais) ? f.mercado : f.pais) || '—',
    mercado: String(f.mercado || ''),
    moneda: String(f.moneda || ''),
    inv: Number(f.inv) || 0,
    usd: f.usd == null ? null : Number(f.usd),
  }));
  d.tasaDe = {};
  for (const x of (d.tasas || [])) d.tasaDe[x.mercado] = x;
  // Bandera y moneda de cada país, sacadas de sus propias filas.
  d.flagDe = {}; d.monedaDe = {};
  for (const r of d.rows) {
    if (!d.flagDe[r.pais]) d.flagDe[r.pais] = bandera(r.mercado);
    if (!d.monedaDe[r.pais]) d.monedaDe[r.pais] = r.moneda;
  }
  return d;
}

function flagPais(p) { return (actual.flagDe && actual.flagDe[p]) ? actual.flagDe[p] + ' ' : ''; }

// Países en el orden fijo del original; uno nuevo va al final, alfabético.
function ordenPaises(set) {
  return [...PORD.filter((p) => set.has(p)), ...[...set].filter((p) => !PORD.includes(p)).sort()];
}

const FILTROS_LATAM = () => [
  ['pais', t('pais')], ['cli', t('cliente')], ['mes', t('mes')], ['prov', t('proveedor')],
];

function pintarLatam(d, reiniciar) {
  if (reiniciar) { af = {}; lusd = false; }
  $$('home').classList.add('hidden');
  $$('detail').classList.remove('hidden');
  $$('tabs').innerHTML = '';
  $$('avisoDet').innerHTML = avisoAdmin();
  $$('meta').innerHTML = `<span>${esc(t('datosAl'))} <b>${esc(fechaHora(d.ultima_carga))}</b></span><span>${esc(t('anio'))} <b>${esc(d.anio || anio)}</b></span>`;
  $$('filtTitle').textContent = t('filtros');
  $$('clrAllBtn').textContent = t('limpiarAll');
  $$('clrAllBtn').onclick = () => { af = {}; sF(); updL(); };

  // Moneda Local / USD
  const cg = document.createElement('div');
  cg.className = 'fgrp';
  cg.innerHTML = `<div class="fl">${esc(t('moneda'))}</div>`;
  const opts = document.createElement('div');
  opts.className = 'fopts';
  for (const [usd, txt] of [[false, t('monedaLocal')], [true, 'USD']]) {
    const lb = document.createElement('label');
    lb.className = 'fopt' + (lusd === usd ? ' on' : '');
    const rb = document.createElement('input');
    rb.type = 'radio'; rb.name = 'curr'; rb.checked = lusd === usd;
    rb.addEventListener('change', () => {
      lusd = usd;
      for (const x of opts.querySelectorAll('.fopt')) x.classList.toggle('on', x.contains(rb));
      updL();
    });
    lb.appendChild(rb);
    lb.appendChild(document.createTextNode(' ' + txt));
    opts.appendChild(lb);
  }
  cg.appendChild(opts);

  bldF(d.rows, FILTROS_LATAM(), updL, { antes: cg });
  updL();
}

function gfrL() { return actual.rows.filter((r) => pasaFiltros(r)); }

function updL() {
  const recs = gfrL();
  const provs = new Set(), paises = new Set();
  for (const r of recs) { if (!vacioTxt(r.prov)) provs.add(r.prov); paises.add(r.pais); }
  const nota = $$('nota');

  if (lusd) {
    // En USD sí se suma entre países: para eso está la conversión.
    const ti = recs.reduce((s, r) => s + (r.usd || 0), 0);
    $$('kpis').innerHTML =
      `<div class="mkpi hl"><div class="kl">USD ${esc(t('total'))}</div><div class="kv">${esc(fusd(ti))}</div></div>` +
      `<div class="mkpi"><div class="kl">${esc(t('provs'))}</div><div class="kv">${provs.size}</div></div>` +
      `<div class="mkpi"><div class="kl">${esc(t('paises'))}</div><div class="kv">${paises.size}</div></div>`;
    // Nota discreta: la tasa vigente de cada mercado y los que no tienen.
    const mercs = [...new Set(recs.map((r) => r.mercado))].sort();
    let n = '';
    for (const m of mercs) {
      const tasa = actual.tasaDe[m];
      const sinUsd = recs.some((r) => r.mercado === m && r.usd == null);
      if (tasa) {
        const v = Number(tasa.valor_por_usd).toLocaleString('es-CO', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        n += `<span>${esc(bandera(m))} ${esc(tasa.moneda || m)}: ${esc(t('tasa').replace('{v}', v).replace('{d}', fecha(tasa.vigente_desde)))}</span>`;
      }
      if (!tasa || sinUsd) n += `<span class="falta">${esc(bandera(m))} ${esc(m)}: ${esc(t('sinTasa'))}</span>`;
    }
    nota.innerHTML = n;
    nota.classList.toggle('hidden', !n);
  } else {
    // Moneda local: un KPI por país, cada uno en su moneda; nunca un total.
    let kh = '';
    [...paises].sort().forEach((p, i) => {
      const tot = recs.reduce((s, r) => s + (r.pais === p ? r.inv : 0), 0);
      kh += `<div class="mkpi${i === 0 ? ' hl' : ''}"><div class="kl">${esc(flagPais(p) + p)}</div><div class="kv">${esc(fc(tot, actual.monedaDe[p]))}</div></div>`;
    });
    kh += `<div class="mkpi"><div class="kl">${esc(t('provs'))}</div><div class="kv">${provs.size}</div></div>`;
    $$('kpis').innerHTML = kh;
    nota.innerHTML = '';
    nota.classList.add('hidden');
  }
  renL(recs);
}

function renL(recs) {
  const el = $$('out');
  el.innerHTML = '';
  if (!recs.length) { el.innerHTML = `<div class="vacio">${esc(t('sinFilas'))}</div>`; return; }

  // Agregado por proveedor. Las barras y los totales van en USD (una fila sin
  // tasa cuenta 0 en USD y se avisa en la nota); lo local vive en byPLC.
  const byProv = {};
  for (const r of recs) {
    if (!byProv[r.prov]) byProv[r.prov] = { usd: 0, byP: {}, byPLC: {}, byTC: {} };
    const d = byProv[r.prov], u = r.usd || 0;
    d.usd += u;
    d.byP[r.pais] = (d.byP[r.pais] || 0) + u;
    d.byPLC[r.pais] = (d.byPLC[r.pais] || 0) + r.inv;
    d.byTC[r.tc] = (d.byTC[r.tc] || 0) + u;
  }
  const pa = Object.entries(byProv).sort((a, b) => b[1].usd - a[1].usd);
  const mx = pa.length && pa[0][1].usd > 0 ? pa[0][1].usd : 1;
  const gt = pa.reduce((s, [, d]) => s + d.usd, 0);

  const paisSet = new Set(recs.map((r) => r.pais)), tcSet = new Set(recs.map((r) => r.tc));
  const paises = ordenPaises(paisSet);
  const tcs = [...tcSet].sort();
  const pcol = {}; paises.forEach((p, i) => { pcol[p] = PCOL[p] || CL[i % CL.length]; });
  const tcol = {}; tcs.forEach((tc, i) => { tcol[tc] = TCCL[i % TCCL.length]; });

  apilada(el, t('provPais'), pa, mx, paises, pcol, (p) => flagPais(p) + p, 'byP');
  tablaPais(el, pa, gt, paises);
  apilada(el, t('provTC'), pa, mx, tcs, tcol, (x) => x, 'byTC');
}

// Barras apiladas por proveedor: cada barra se parte por `dim` (país o tipo de
// costo), con el share adentro o superpuesto cuando el segmento es muy angosto.
function apilada(el, titulo, pa, mx, segs, colores, etiqueta, dim) {
  let s = `<h4>${titulo}</h4><div class="leyenda">`;
  for (const sg of segs) s += `<span><i style="background:${colores[sg]}"></i>${esc(etiqueta(sg))}</span>`;
  s += '</div><div class="hbars">';
  for (const [pn, d] of pa) {
    const barW = Math.max(d.usd, 0) / mx * 100;
    const fuera = [];
    let acum = 0;
    s += `<div class="hbar-row"><div class="hbar-name" title="${esc(pn)}">${esc(pn)}</div><div class="hbar-track libre"><div class="pila" style="width:${barW}%">`;
    for (const sg of segs) {
      const v = d[dim][sg] || 0;
      if (v <= 0) continue;
      const sp = d.usd > 0 ? v / d.usd * 100 : 0;
      const ttl = esc(`${etiqueta(sg)}: ${fusd(v)} (${fp(sp)})`);
      if (barW * sp / 100 > 12) s += `<div class="seg" style="flex:0 0 ${sp}%;background:${colores[sg]}" title="${ttl}">${fp(sp)}</div>`;
      else { s += `<div class="seg" style="flex:0 0 ${sp}%;background:${colores[sg]}" title="${ttl}"></div>`; fuera.push({ l: barW * (acum + sp / 2) / 100, v: fp(sp) }); }
      acum += sp;
    }
    s += '</div>';
    for (const f of fuera) s += `<span class="seg-out" style="left:${f.l}%">${f.v}</span>`;
    s += `</div><div class="hbar-pct" style="font-size:10.5px">${esc(fusd(d.usd))}</div></div>`;
  }
  panel(el, s + '</div>');
}

// Tabla Proveedor × País. En USD las celdas van en USD; en moneda local cada
// columna va en la moneda de su país. El total por proveedor y el share van
// siempre en USD, como en el original: nunca se suman monedas locales.
function tablaPais(el, pa, gt, paises) {
  let s = `<h4>${esc(t('detPais'))}</h4><div class="tscroll"><table class="dt"><thead><tr><th>${esc(t('proveedor'))}</th>`;
  for (const p of paises) s += `<th class="num">${esc(flagPais(p) + p)}</th>`;
  s += `<th class="num" style="font-weight:700">TOTAL USD</th><th class="num">${esc(t('share'))}</th></tr></thead><tbody>`;
  const totCol = {};
  for (const [pn, d] of pa) {
    s += `<tr><td style="font-weight:600">${esc(pn)}</td>`;
    for (const p of paises) {
      const v = lusd ? (d.byP[p] || 0) : (d.byPLC[p] || 0);
      totCol[p] = (totCol[p] || 0) + v;
      s += `<td class="num">${v > 0 ? esc(lusd ? fusd(v) : fc(v, actual.monedaDe[p])) : '—'}</td>`;
    }
    s += `<td class="num" style="font-weight:700">${esc(fusd(d.usd))}</td><td class="num">${fp(gt > 0 ? d.usd / gt * 100 : 0)}</td></tr>`;
  }
  s += `<tr class="tot"><td>TOTAL</td>`;
  for (const p of paises) s += `<td class="num">${esc(lusd ? fusd(totCol[p] || 0) : fc(totCol[p] || 0, actual.monedaDe[p]))}</td>`;
  s += `<td class="num">${esc(fusd(gt))}</td><td class="num">100.0%</td></tr></tbody></table></div>`;
  panel(el, s);
}

// ------------------------------------------------------------------ Excel

function dlXLS() {
  if (typeof XLSX === 'undefined') { alert(t('errCarga') + ': Excel'); return; }
  const mn = t('mn'), wb = XLSX.utils.book_new();
  let rows, cols, nombre;
  if (vista.tipo === 'mercado') {
    const cur = actual.c;
    rows = [t('xls')];
    for (const r of gfr()) rows.push([mn[r.m] || r.m, r.w, r.prov, r.tc, r.fmt, r.camp, r.sub, Math.round(r.cost * 100) / 100, r.cli, r.med, r.city, cur]);
    cols = [8, 8, 20, 18, 18, 30, 30, 18, 20, 10, 15, 8];
    nombre = `OOH_${actual.codigo}_${anio}.xlsx`;
  } else if (vista.tipo === 'latam') {
    rows = [[t('proveedor'), t('tipoCosto'), t('cliente'), t('mes'), t('pais'), 'Mercado', t('moneda'), t('invLocal'), 'USD']];
    for (const r of gfrL()) rows.push([r.prov, r.tc, r.cli, mn[r.mes] || r.mes, r.pais, r.mercado, r.moneda, Math.round(r.inv * 100) / 100, r.usd == null ? '' : Math.round(r.usd * 100) / 100]);
    cols = [24, 18, 20, 8, 14, 9, 8, 20, 14];
    nombre = `OOH_LATAM_${anio}.xlsx`;
  } else return;
  const ws = XLSX.utils.aoa_to_sheet(rows);
  ws['!cols'] = cols.map((wch) => ({ wch }));
  XLSX.utils.book_append_sheet(wb, ws, 'INVERSION');
  XLSX.writeFile(wb, nombre);
}

// ------------------------------------------------------------------ Eventos

$$('lES').addEventListener('click', () => setLang('es'));
$$('lPT').addEventListener('click', () => setLang('pt'));
$$('dlBtn').addEventListener('click', dlXLS);
$$('salirBtn').addEventListener('click', salir);
$$('btnVolver').addEventListener('click', () => mostrar({ tipo: 'portada' }));
$$('temaBtn').addEventListener('click', () => {
  const nuevo = temaEfectivo() === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', nuevo);
  guardarPref(CLAVE_TEMA, nuevo);
  pintarBotonTema();
});
$$('fToggle').addEventListener('click', () => {
  const side = $$('side');
  side.classList.toggle('abierto');
  $$('fToggle').setAttribute('aria-expanded', side.classList.contains('abierto'));
  sF();
});
if (window.matchMedia) matchMedia('(prefers-color-scheme: dark)').addEventListener('change', pintarBotonTema);

const idiomaGuardado = leerPref(CLAVE_IDIOMA);
if (idiomaGuardado === 'pt' || idiomaGuardado === 'es') { lang = idiomaGuardado; document.documentElement.lang = lang; }
llenarAnios();
pintarBarra();
iniciar().catch((e) => mostrarError(e, () => iniciar()));
