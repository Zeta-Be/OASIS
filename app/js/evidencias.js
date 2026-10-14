// Evidencias de implementación: fotos, videos y enlaces de cada material.
// Lo comparten el portal (el proveedor sube; la agencia mira) y Materiales
// (los internos miran). Va después de comun.js, componentes.js y tramos.js.
//
// Los archivos viven en el bucket privado «evidencias» de Supabase Storage, en
// {proveedor_id}/{material_id}/{uuid}.{ext}, y se ven con URLs firmadas de
// corta duración. La tabla evidencias guarda una fila por archivo o enlace; el
// tamaño real lo pone la base leyendo Storage, no el navegador.

const BUCKET_EVIDENCIAS = 'evidencias';
const MB = 1024 * 1024;
const MAX_FOTO = 2 * MB;        // después de comprimir
const MAX_VIDEO = 50 * MB;      // tope por archivo del plan gratis
const ANCHO_FOTO = 1600;
const TIPOS_VIDEO = ['video/mp4', 'video/quicktime', 'video/webm'];
const EXT_VIDEO = { 'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/webm': 'webm' };
const VIGENCIA_FIRMA = 600;     // segundos que vale una URL firmada

const COLUMNAS_EVIDENCIA = 'id, material_id, tipo, ruta_storage, url, nombre_archivo, tamano_bytes, subido_por, en';

// Igual que fn_es_url en la base: https, con dominio, sin espacios.
const RE_URL = /^https:\/\/[^\s/?#]+\.[^\s/?#]+([/?#]\S*)?$/i;
const esUrl = (s) => !!s && RE_URL.test(s) && s.length <= 2000;

// ¿El enlace responde? El navegador no deja leer la respuesta de otro sitio
// (CORS), así que esto solo distingue «el servidor contestó» de «no existe o no
// se pudo conectar». No sabe si un archivo de Drive está compartido.
async function enlaceResponde(url) {
  if (!/^https:\/\//i.test(url)) return { ok: false, motivo: 'Usa un enlace https://' };
  try {
    await fetch(url, { mode: 'no-cors', cache: 'no-store', signal: AbortSignal.timeout(8000) });
    return { ok: true };
  } catch (e) {
    return { ok: false, motivo: e.name === 'TimeoutError' ? 'El enlace no respondió en 8 s' : 'No se pudo abrir el enlace' };
  }
}

function tamanoHumano(b) {
  if (!esNumero(b)) return '';
  return b >= MB ? `${(b / MB).toLocaleString('es-CO', { maximumFractionDigits: 1 })} MB`
    : `${Math.max(1, Math.round(b / 1024))} KB`;
}

// Todas las evidencias que el usuario puede ver (RLS decide cuáles).
async function cargarEvidencias() {
  return traerTodo(() => sb.from('evidencias').select(COLUMNAS_EVIDENCIA).order('material_id').order('en'));
}

// URLs firmadas para varias rutas: { ruta: url }.
async function firmarEvidencias(rutas) {
  if (!rutas.length) return {};
  const { data, error } = await sb.storage.from(BUCKET_EVIDENCIAS).createSignedUrls(rutas, VIGENCIA_FIRMA);
  if (error) throw error;
  const urls = {};
  for (const d of data) if (d.signedUrl) urls[d.path] = d.signedUrl;
  return urls;
}

// Foto a máximo 1600 px de ancho, WebP (o JPEG si el navegador no sabe) al 85 %.
// Si aun así pasa de 2 MB, baja la calidad. La orientación de la cámara se respeta.
async function comprimirFoto(archivo) {
  let imagen;
  try {
    imagen = await createImageBitmap(archivo, { imageOrientation: 'from-image' });
  } catch {
    throw new Error('No se pudo leer la foto. Usa JPEG, PNG o WebP.');
  }
  const escala = Math.min(1, ANCHO_FOTO / imagen.width);
  const lienzo = document.createElement('canvas');
  lienzo.width = Math.round(imagen.width * escala);
  lienzo.height = Math.round(imagen.height * escala);
  lienzo.getContext('2d').drawImage(imagen, 0, 0, lienzo.width, lienzo.height);
  imagen.close();

  const aBlob = (tipo, calidad) => new Promise(res => lienzo.toBlob(res, tipo, calidad));
  for (const calidad of [0.85, 0.75, 0.65]) {
    let blob = await aBlob('image/webp', calidad);
    if (!blob || blob.type !== 'image/webp') blob = await aBlob('image/jpeg', calidad);
    if (blob && blob.size <= MAX_FOTO) return blob;
  }
  throw new Error('La foto sigue pasando de 2 MB después de comprimirla.');
}

// Sube un blob al bucket con barra de progreso (supabase-js no da progreso).
function subirAlBucket(ruta, blob, alProgreso) {
  return new Promise(async (resolve, reject) => {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) { reject(new Error('La sesión venció. Vuelve a entrar.')); return; }
    const xhr = new XMLHttpRequest();
    const destino = `${window.OASIS_CONFIG.supabaseUrl}/storage/v1/object/${BUCKET_EVIDENCIAS}/${ruta}`;
    xhr.open('POST', destino);
    xhr.setRequestHeader('Authorization', `Bearer ${session.access_token}`);
    xhr.setRequestHeader('apikey', window.OASIS_CONFIG.supabaseKey);
    xhr.setRequestHeader('Content-Type', blob.type);
    xhr.setRequestHeader('x-upsert', 'false');
    xhr.upload.onprogress = (ev) => { if (ev.lengthComputable) alProgreso(ev.loaded / ev.total); };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) { resolve(); return; }
      let msg = `Storage respondió ${xhr.status}`;
      try { const r = JSON.parse(xhr.responseText); msg = r.message || r.error || msg; } catch { /* texto plano */ }
      if (xhr.status === 413 || /size/i.test(msg)) msg = 'El archivo pasa del máximo permitido';
      if (/row-level security|unauthorized|403/i.test(msg)) msg = 'Sin permiso para subir a este material';
      reject(new Error(msg));
    };
    xhr.onerror = () => reject(new Error('Se cortó la conexión mientras subía'));
    xhr.send(blob);
  });
}

function mensajeErrorEvidencia(error) {
  if (!error) return 'Error desconocido';
  if (error.code === '42501') return error.message || 'Sin permiso';
  return error.message || String(error);
}

// ------------------------------------------------------------------ Panel
// Panel lateral con las evidencias de un material. `puedeSubir` solo para
// PROVEEDOR; borrar, lo que subió el propio usuario (la base lo hace cumplir).
const PanelEvidencias = {
  props: {
    material: Object,         // { id, codigo, ubicacion }
    evidencias: Array,        // las de este material
    puedeSubir: Boolean,
    usuario: Object,
  },
  emits: ['cerrar', 'agregada', 'borrada'],
  data: () => ({
    urls: {},          // ruta -> URL firmada
    errorFirmas: '',
    subidas: [],       // en curso: { k, nombre, tipo, progreso, estado, error, vista }
    enlace: '',
    errorEnlace: '',
    guardandoEnlace: false,
    confirmar: null,   // id de la evidencia a punto de borrarse
    borrando: null,
  }),
  computed: {
    archivos() { return this.evidencias.filter(e => e.tipo !== 'ENLACE'); },
    enlaces() { return this.evidencias.filter(e => e.tipo === 'ENLACE'); },
    ocupado() { return this.subidas.some(s => s.estado === 'subiendo'); },
  },
  watch: {
    // Firma lo nuevo cada vez que cambia la lista (al abrir y al subir).
    evidencias: { handler() { this.firmar(); }, immediate: true },
  },
  methods: {
    tamanoHumano,
    fechaHumana(iso) { return iso ? fechaHumana(iso.slice(0, 10)) : ''; },
    esMia(e) { return e.subido_por === this.usuario.id; },
    async firmar(todo = false) {
      const rutas = this.archivos.map(e => e.ruta_storage).filter(r => todo || !this.urls[r]);
      if (!rutas.length) return;
      try {
        this.urls = { ...this.urls, ...(await firmarEvidencias(rutas)) };
        this.errorFirmas = '';
      } catch (e) {
        console.error(e);
        this.errorFirmas = 'No se pudieron abrir los archivos: ' + mensajeErrorEvidencia(e);
      }
    },
    // Abre en grande con una firma recién hecha: la de la miniatura pudo vencer.
    async abrir(e) {
      const ventana = window.open('', '_blank');
      try {
        const urls = await firmarEvidencias([e.ruta_storage]);
        ventana.location = urls[e.ruta_storage];
      } catch (err) {
        ventana.close();
        this.errorFirmas = 'No se pudo abrir: ' + mensajeErrorEvidencia(err);
      }
    },

    elegirArchivos() { this.$refs.archivos.click(); },
    async alElegir(ev) {
      const lista = [...ev.target.files];
      ev.target.value = '';
      for (const f of lista) await this.subir(f);
    },

    async subir(archivo) {
      const s = { k: Math.random(), nombre: archivo.name, tipo: '', progreso: 0, estado: 'preparando', error: '', vista: '' };
      this.subidas.unshift(s);
      const fila = this.subidas[0];   // la versión reactiva
      let ruta = null;
      try {
        let blob, tipo, ext;
        if (archivo.type.startsWith('image/')) {
          tipo = 'FOTO';
          blob = await comprimirFoto(archivo);
          ext = blob.type === 'image/webp' ? 'webp' : 'jpg';
        } else if (archivo.type.startsWith('video/')) {
          tipo = 'VIDEO';
          if (!TIPOS_VIDEO.includes(archivo.type)) throw new Error('Video en formato no admitido. Usa MP4, MOV o WebM, o compártelo por enlace.');
          if (archivo.size > MAX_VIDEO) throw new Error('Comprime el video o compártelo por enlace (máximo 50 MB).');
          blob = archivo;
          ext = EXT_VIDEO[archivo.type];
        } else {
          throw new Error('Solo fotos o videos. Para otro tipo de archivo, pega un enlace.');
        }
        fila.tipo = tipo;
        fila.vista = URL.createObjectURL(blob);
        fila.estado = 'subiendo';

        ruta = `${this.usuario.proveedor_id}/${this.material.id}/${crypto.randomUUID()}.${ext}`;
        await subirAlBucket(ruta, blob, (p) => { fila.progreso = p; });

        const { data, error } = await sb.from('evidencias')
          .insert({ material_id: this.material.id, tipo, ruta_storage: ruta, tamano_bytes: blob.size, nombre_archivo: archivo.name })
          .select(COLUMNAS_EVIDENCIA).single();
        if (error) {
          // Sin fila no cuenta: se quita el archivo para no dejarlo huérfano.
          await sb.storage.from(BUCKET_EVIDENCIAS).remove([ruta]);
          throw error;
        }
        fila.estado = 'listo';
        this.$emit('agregada', data);
        setTimeout(() => {
          const i = this.subidas.indexOf(fila);
          if (i >= 0) { URL.revokeObjectURL(fila.vista); this.subidas.splice(i, 1); }
        }, 1500);
      } catch (e) {
        console.error('No se subió la evidencia', e);
        fila.estado = 'error';
        fila.error = mensajeErrorEvidencia(e);
      }
    },
    quitarSubida(s) {
      if (s.vista) URL.revokeObjectURL(s.vista);
      this.subidas.splice(this.subidas.indexOf(s), 1);
    },

    async agregarEnlace() {
      const url = this.enlace.trim();
      this.errorEnlace = '';
      if (!esUrl(url)) { this.errorEnlace = 'Tiene que ser un enlace que empiece por https://'; return; }
      this.guardandoEnlace = true;
      const prueba = await enlaceResponde(url);
      if (!prueba.ok) { this.errorEnlace = prueba.motivo; this.guardandoEnlace = false; return; }
      const { data, error } = await sb.from('evidencias')
        .insert({ material_id: this.material.id, tipo: 'ENLACE', url })
        .select(COLUMNAS_EVIDENCIA).single();
      this.guardandoEnlace = false;
      if (error) { this.errorEnlace = mensajeErrorEvidencia(error); return; }
      this.enlace = '';
      this.$emit('agregada', data);
    },

    // Archivo primero, fila después. Si el archivo no se borra, la fila se
    // queda: mejor una evidencia visible que un archivo huérfano que nadie ve.
    // Ojo: si RLS no deja borrar, Storage no da error, devuelve la lista vacía.
    async borrar(e) {
      this.borrando = e.id;
      let error = null;
      if (e.ruta_storage) {
        const r = await sb.storage.from(BUCKET_EVIDENCIAS).remove([e.ruta_storage]);
        if (r.error) error = r.error;
        else if (!r.data || !r.data.length) error = { message: 'Storage no borró el archivo (¿no es tuyo?)' };
      }
      if (!error) {
        const r = await sb.from('evidencias').delete().eq('id', e.id).select('id');
        if (r.error) error = r.error;
        else if (!r.data.length) error = { message: 'La evidencia no es tuya' };
        // Archivo borrado y fila no: queda una fila sin archivo. Se avisa.
        if (error && e.ruta_storage) error.message = 'Se borró el archivo pero no la evidencia: ' + error.message;
      }
      this.borrando = null;
      this.confirmar = null;
      if (error) {
        console.error('No se borró la evidencia', e, error);
        this.errorFirmas = 'No se pudo borrar: ' + mensajeErrorEvidencia(error);
        return;
      }
      this.$emit('borrada', e.id);
    },
    cerrar() { if (!this.ocupado) this.$emit('cerrar'); },
  },
  mounted() {
    this._esc = (ev) => { if (ev.key === 'Escape') this.cerrar(); };
    document.addEventListener('keydown', this._esc);
    // Las firmas duran 10 minutos: se renuevan mientras el panel está abierto.
    this._renovar = setInterval(() => this.firmar(true), (VIGENCIA_FIRMA - 60) * 1000);
  },
  unmounted() {
    document.removeEventListener('keydown', this._esc);
    clearInterval(this._renovar);
    for (const s of this.subidas) if (s.vista) URL.revokeObjectURL(s.vista);
  },
  template: `
    <div class="panel-fondo" @pointerdown.self="cerrar">
      <aside class="panel panel-evidencias" role="dialog" aria-labelledby="ev-titulo">
        <header class="panel-cab">
          <div>
            <div class="eyebrow">Material {{ material.codigo }}<template v-if="material.ubicacion"> · {{ material.ubicacion }}</template></div>
            <h2 id="ev-titulo">Evidencias</h2>
          </div>
          <button type="button" class="cerrar" title="Cerrar (Esc)" @click="cerrar">×</button>
        </header>

        <div class="panel-cuerpo ev-cuerpo">
          <div v-if="errorFirmas" class="alerta error">{{ errorFirmas }}</div>

          <!-- Agregar: solo el proveedor -->
          <section v-if="puedeSubir" class="ev-agregar">
            <div class="etiqueta">Agregar evidencia</div>
            <div class="ev-acciones">
              <button type="button" class="btn p" @click="elegirArchivos">Subir fotos o videos</button>
              <span class="campo-pista">Desde el celular puedes tomarlas con la cámara. Videos de hasta 50 MB.</span>
            </div>
            <input ref="archivos" type="file" multiple accept="image/jpeg,image/png,image/webp,image/heic,video/mp4,video/quicktime,video/webm"
                   hidden @change="alElegir">

            <form class="ev-enlace" :class="{ err: errorEnlace }" @submit.prevent="agregarEnlace" novalidate>
              <div class="campo">
                <label for="ev-url">O pega un enlace</label>
                <input id="ev-url" v-model="enlace" placeholder="https://drive.google.com/…" autocomplete="off"
                       @input="errorEnlace = ''">
              </div>
              <button type="submit" class="btn" :disabled="guardandoEnlace || !enlace.trim()">
                {{ guardandoEnlace ? 'Comprobando…' : 'Agregar enlace' }}
              </button>
            </form>
            <div v-if="errorEnlace" class="campo-error">{{ errorEnlace }}</div>

            <ul v-if="subidas.length" class="ev-subidas">
              <li v-for="s in subidas" :key="s.k" :class="s.estado">
                <div class="ev-mini">
                  <img v-if="s.vista && s.tipo === 'FOTO'" :src="s.vista" alt="">
                  <video v-else-if="s.vista" :src="s.vista + '#t=0.1'" muted playsinline preload="metadata"></video>
                </div>
                <div class="ev-sub-info">
                  <div class="ev-nombre" :title="s.nombre">{{ s.nombre }}</div>
                  <div v-if="s.estado === 'error'" class="campo-error">{{ s.error }}</div>
                  <div v-else class="ev-barra"><span :style="{ width: Math.round(s.progreso * 100) + '%' }"></span></div>
                  <div class="ev-meta mono">
                    {{ s.estado === 'preparando' ? 'preparando…' : s.estado === 'subiendo' ? Math.round(s.progreso * 100) + ' %' : s.estado === 'listo' ? 'subida' : '' }}
                  </div>
                </div>
                <button v-if="s.estado === 'error'" type="button" class="mini" @click="quitarSubida(s)">Quitar</button>
              </li>
            </ul>
          </section>

          <!-- Lo que hay -->
          <div class="etiqueta">{{ archivos.length }} {{ archivos.length === 1 ? 'archivo' : 'archivos' }}</div>
          <div v-if="!archivos.length" class="ev-vacio">Sin fotos ni videos.</div>
          <ul v-else class="ev-galeria">
            <li v-for="e in archivos" :key="e.id">
              <button type="button" class="ev-mini grande" :title="'Abrir ' + (e.nombre_archivo || '') + ' en grande'" @click="abrir(e)">
                <img v-if="e.tipo === 'FOTO' && urls[e.ruta_storage]" :src="urls[e.ruta_storage]" alt="" loading="lazy">
                <video v-else-if="e.tipo === 'VIDEO' && urls[e.ruta_storage]" :src="urls[e.ruta_storage] + '#t=0.1'"
                       muted playsinline preload="metadata"></video>
                <span v-if="e.tipo === 'VIDEO'" class="ev-sello mono">VIDEO</span>
              </button>
              <div class="ev-meta mono">{{ fechaHumana(e.en) }} · {{ tamanoHumano(e.tamano_bytes) }}</div>
              <div v-if="puedeSubir && esMia(e)" class="ev-borrar">
                <template v-if="confirmar === e.id">
                  <button type="button" class="mini peligro" :disabled="borrando === e.id" @click="borrar(e)">Sí, borrar</button>
                  <button type="button" class="mini" @click="confirmar = null">No</button>
                </template>
                <button v-else type="button" class="mini" @click="confirmar = e.id">Borrar</button>
              </div>
            </li>
          </ul>

          <div class="etiqueta">{{ enlaces.length }} {{ enlaces.length === 1 ? 'enlace' : 'enlaces' }}</div>
          <div v-if="!enlaces.length" class="ev-vacio">Sin enlaces.</div>
          <ul v-else class="ev-enlaces">
            <li v-for="e in enlaces" :key="e.id">
              <a :href="e.url" target="_blank" rel="noopener" :title="e.url">{{ e.url }}</a>
              <span class="ev-meta mono">{{ fechaHumana(e.en) }}</span>
              <span v-if="puedeSubir && esMia(e)" class="ev-borrar">
                <template v-if="confirmar === e.id">
                  <button type="button" class="mini peligro" :disabled="borrando === e.id" @click="borrar(e)">Sí, borrar</button>
                  <button type="button" class="mini" @click="confirmar = null">No</button>
                </template>
                <button v-else type="button" class="mini" @click="confirmar = e.id">Borrar</button>
              </span>
            </li>
          </ul>
        </div>

        <footer class="panel-pie">
          <div class="botones">
            <button type="button" class="btn" :disabled="ocupado" @click="cerrar">{{ ocupado ? 'Subiendo…' : 'Cerrar' }}</button>
          </div>
        </footer>
      </aside>
    </div>`,
};
