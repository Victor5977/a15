#!/bin/bash
# ==========================================================================
# a15.sh - Instalador de la Actividad 15 (GSO0 - Automatizacion Resiliente)
# Uso:
#   En vm-destino:  sudo bash a15.sh destino
#   En vm-origen:   sudo bash a15.sh origen <IP_DE_VM_DESTINO>
# ==========================================================================
set -euo pipefail

MODO="${1:-}"
AUTOR="Victor Eduardo Alonzo Lopez"
EMAIL="alonzovictor760@gmail.com"
HOY="$(date +%Y-%m-%d)"

titulo() { echo; echo "==================== $* ===================="; }

if [[ $EUID -ne 0 ]]; then echo "Ejecuta con sudo: sudo bash a15.sh $MODO"; exit 1; fi

poner_hostname() {
    local nuevo="$1"
    local viejo; viejo="$(hostname)"
    hostnamectl set-hostname "$nuevo"
    sed -i "s/\b${viejo}\b/${nuevo}/g" /etc/hosts
    grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 ${nuevo}" >> /etc/hosts
}

git_versionar() {
    # $1 = carpeta, $2 = usuario dueno, $3 = mensaje
    local dir="$1" usr="$2" msg="$3"
    sudo -u "$usr" git -C "$dir" init -q 2>/dev/null || true
    sudo -u "$usr" git -C "$dir" config user.name "$AUTOR"
    sudo -u "$usr" git -C "$dir" config user.email "$EMAIL"
    sudo -u "$usr" git -C "$dir" add -A
    sudo -u "$usr" git -C "$dir" commit -q -m "$msg" || true
}

# ==========================================================================
#                               VM-DESTINO
# ==========================================================================
setup_destino() {
    titulo "1/5 Nombre de la maquina"
    poner_hostname vm-destino

    titulo "2/5 Paquetes (ssh, rsync, git)"
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q openssh-server rsync git
    systemctl enable --now ssh

    titulo "3/5 Carpeta de respaldos y bitacora"
    mkdir -p /home/student/respaldos
    chown student:student /home/student/respaldos
    touch /var/log/cronos_disk_alerts.log
    chmod 640 /var/log/cronos_disk_alerts.log

    titulo "4/5 Script cronos_monitor.sh"
    mkdir -p /opt/cronos
    cat > /opt/cronos/cronos_monitor.sh <<EOF_MON
#!/bin/bash
# ==========================================================================
# Script       : cronos_monitor.sh
# Autor        : ${AUTOR}
# Fecha        : ${HOY}
# Version      : 1.0
# Descripcion  : Supervisa el porcentaje de uso del sistema de archivos donde
#                se depositan los respaldos recibidos. Si el uso supera el
#                umbral de forma SOSTENIDA (varias lecturas consecutivas)
#                registra una ALERTA CRITICA en /var/log/cronos_disk_alerts.log.
#                Un pico pasajero (ej. rsync escribiendo un archivo grande) no
#                genera alerta.
# Uso          : cronos_monitor.sh [UMBRAL] [LECTURAS] [INTERVALO]
#   UMBRAL     : porcentaje maximo permitido      (por defecto 80)
#   LECTURAS   : lecturas consecutivas requeridas (por defecto 3)
#   INTERVALO  : segundos entre cada lectura      (por defecto 30)
# Dependencias : coreutils (df, tr, date, sleep), gawk (awk)
# Ejecucion    : cron de root, cada 5 minutos
# ==========================================================================
set -uo pipefail

# ---- Rutas absolutas (evita manipulacion de \$PATH) ----
readonly DF=/usr/bin/df
readonly AWK=/usr/bin/awk
readonly TR=/usr/bin/tr
readonly DATE=/usr/bin/date
readonly SLEEP=/usr/bin/sleep

# ---- Configuracion ----
readonly DIR_RESPALDOS="/home/student/respaldos"
readonly LOG_ALERTAS="/var/log/cronos_disk_alerts.log"
readonly UMBRAL="\${1:-80}"
readonly LECTURAS="\${2:-3}"
readonly INTERVALO="\${3:-30}"

# ---- Funciones ----
registrar() {
    # Escribe en la bitacora dedicada con marca de tiempo
    local nivel="\$1"; shift
    echo "[\$(\$DATE '+%Y-%m-%d %H:%M:%S')] [\${nivel}] \$*" >> "\$LOG_ALERTAS"
}

uso_disco() {
    # df -> solo la columna de porcentaje -> fila 2 -> solo digitos
    \$DF --output=pcent "\$DIR_RESPALDOS" | \$AWK 'NR==2' | \$TR -dc '0-9'
}

# ---- Verificacion sostenida (evita falsos positivos) ----
contador=0
while (( contador < LECTURAS )); do
    uso="\$(uso_disco)"
    echo "Lectura \$((contador + 1))/\${LECTURAS}: uso \${uso}% (umbral \${UMBRAL}%)"
    if (( uso <= UMBRAL )); then
        echo "OK: el uso esta dentro del umbral. No se registra alerta."
        exit 0
    fi
    contador=\$((contador + 1))
    if (( contador < LECTURAS )); then
        \$SLEEP "\$INTERVALO"
    fi
done

registrar "ALERTA CRITICA" "Uso de disco en \${uso}% (umbral \${UMBRAL}%) en \${DIR_RESPALDOS}. Sostenido durante \${LECTURAS} lecturas consecutivas."
echo "ALERTA CRITICA registrada en \${LOG_ALERTAS}"
exit 2
EOF_MON
    chown root:root /opt/cronos/cronos_monitor.sh
    chmod 700 /opt/cronos/cronos_monitor.sh
    git_versionar /opt/cronos root "Version inicial de cronos_monitor.sh"

    titulo "5/5 Programacion en cron (root, cada 5 minutos)"
    ( crontab -l 2>/dev/null | grep -v cronos_monitor || true
      echo "*/5 * * * * /opt/cronos/cronos_monitor.sh >/dev/null 2>&1" ) | crontab -
    crontab -l

    titulo "LISTO: vm-destino"
    echo "IP de esta maquina (anotala para vm-origen):"
    hostname -I
}

# ==========================================================================
#                               VM-ORIGEN
# ==========================================================================
setup_origen() {
    local IP_DESTINO="${2:-}"
    if [[ -z "$IP_DESTINO" ]]; then echo "Falta la IP: sudo bash a15.sh origen <IP_DESTINO>"; exit 1; fi

    titulo "1/8 Nombre de la maquina y nombre de vm-destino"
    poner_hostname vm-origen
    sed -i '/ vm-destino$/d' /etc/hosts
    echo "${IP_DESTINO} vm-destino" >> /etc/hosts

    titulo "2/8 Paquetes base"
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl gnupg rsync git openssh-client nodejs npm

    titulo "3/8 MongoDB 8.0 (repositorio oficial firmado con GPG)"
    curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q mongodb-org
    systemctl enable --now mongod
    for i in $(seq 1 30); do
        mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break
        sleep 2
    done

    titulo "4/8 Aplicacion Node.js en /var/www/mi-app"
    mkdir -p /var/www/mi-app
    cat > /var/www/mi-app/package.json <<'EOF_PKG'
{
  "name": "mi-app",
  "version": "1.0.0",
  "description": "Tienda de prueba GSO0 - Node.js + MongoDB",
  "main": "app.js",
  "scripts": { "start": "node app.js" },
  "dependencies": { "mongodb": "^6.10.0" }
}
EOF_PKG
    cat > /var/www/mi-app/config.json <<'EOF_CFG'
{
  "puerto": 3000,
  "mongoUri": "mongodb://127.0.0.1:27017",
  "baseDatos": "tienda"
}
EOF_CFG
    cat > /var/www/mi-app/app.js <<'EOF_APP'
// mi-app: API minima que lista los productos guardados en MongoDB
const http = require('http');
const { MongoClient } = require('mongodb');
const config = require('./config.json');

const cliente = new MongoClient(config.mongoUri);

async function iniciar() {
  await cliente.connect();
  const db = cliente.db(config.baseDatos);
  http.createServer(async (req, res) => {
    const productos = await db.collection('productos').find({}, { projection: { _id: 0 } }).toArray();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ app: 'mi-app', productos }, null, 2));
  }).listen(config.puerto, () => console.log(`mi-app escuchando en el puerto ${config.puerto}`));
}
iniciar().catch(err => { console.error(err); process.exit(1); });
EOF_APP
    chown -R student:student /var/www/mi-app
    sudo -u student bash -c 'cd /var/www/mi-app && npm install --no-audit --no-fund --silent'

    mongosh tienda --quiet --eval '
      if (db.productos.countDocuments() === 0) {
        db.productos.insertMany([
          { nombre: "Audifonos inalambricos", precio: 25.99, stock: 40 },
          { nombre: "Cargador USB-C 20W",     precio: 12.50, stock: 75 },
          { nombre: "Cable HDMI 2m",          precio: 7.25,  stock: 120 },
          { nombre: "Mouse inalambrico",      precio: 15.00, stock: 60 }
        ]);
      }
      print("Productos en la base tienda: " + db.productos.countDocuments());'

    cat > /etc/systemd/system/mi-app.service <<'EOF_SVC'
[Unit]
Description=mi-app (Node.js + MongoDB)
After=network.target mongod.service
Requires=mongod.service

[Service]
User=student
WorkingDirectory=/var/www/mi-app
ExecStart=/usr/bin/node /var/www/mi-app/app.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF_SVC
    systemctl daemon-reload
    systemctl enable --now mi-app
    sleep 3
    curl -s http://127.0.0.1:3000 || true

    titulo "5/8 Carpetas, bitacora y script cronos_backup.sh"
    mkdir -p /opt/cronos /var/backups/cronos
    touch /var/log/cronos_backup.log
    chown student:student /opt/cronos /var/backups/cronos /var/log/cronos_backup.log
    chmod 640 /var/log/cronos_backup.log
    cat > /opt/cronos/cronos_backup.sh <<EOF_BAK
#!/bin/bash
# ==========================================================================
# Script       : cronos_backup.sh
# Autor        : ${AUTOR}
# Fecha        : ${HOY}
# Version      : 1.0
# Descripcion  : Respaldo distribuido de mi-app. Genera un dump consistente de
#                MongoDB (mongodump), lo empaqueta y comprime junto con el
#                codigo fuente y la configuracion de la aplicacion Node.js, y
#                lo transfiere con rsync (sobre SSH) a vm-destino.
#                Si hay una interrupcion o un error, trap borra los archivos
#                temporales y el paquete a medias.
# Uso          : cronos_backup.sh [HOST_DESTINO]
#   HOST_DESTINO : nombre o IP de la maquina receptora (por defecto vm-destino)
#   PAUSA_DEMO   : (variable opcional) segundos de pausa tras el dump, solo
#                  para demostrar el trap con Ctrl+C. Ej: PAUSA_DEMO=20
# Dependencias : mongodb-database-tools (mongodump), tar, gzip, rsync,
#                openssh-client (llave SSH sin contrasena hacia vm-destino)
# Bitacora     : /var/log/cronos_backup.log
# Ejecucion    : cron del usuario student, todas las noches a las 02:00
# ==========================================================================
set -Eeuo pipefail

# ---- Rutas absolutas (evita manipulacion de \$PATH) ----
readonly MONGODUMP=/usr/bin/mongodump
readonly TAR=/usr/bin/tar
readonly RSYNC=/usr/bin/rsync
readonly SSH=/usr/bin/ssh
readonly DATE=/usr/bin/date
readonly RM=/usr/bin/rm
readonly MKDIR=/usr/bin/mkdir
readonly DU=/usr/bin/du
readonly CUT=/usr/bin/cut
readonly LS=/usr/bin/ls
readonly TAIL=/usr/bin/tail
readonly XARGS=/usr/bin/xargs
readonly SLEEP=/usr/bin/sleep

# ---- Configuracion ----
readonly APP_PADRE="/var/www"
readonly APP_NOMBRE="mi-app"
readonly DB_NOMBRE="tienda"
readonly DESTINO_HOST="\${1:-vm-destino}"
readonly DESTINO_USUARIO="student"
readonly DESTINO_DIR="/home/student/respaldos"
readonly LOCAL_DIR="/var/backups/cronos"
readonly BITACORA="/var/log/cronos_backup.log"
readonly RETENCION_LOCAL=7
readonly FECHA="\$(\$DATE '+%Y%m%d_%H%M%S')"
readonly TMP_DIR="\${LOCAL_DIR}/tmp_\${FECHA}"
readonly PAQUETE="\${LOCAL_DIR}/backup_\${FECHA}.tar.gz"

# ---- Toda la salida estandar y de errores va a la bitacora ----
exec >> "\$BITACORA" 2>&1

# ---- Funciones de registro reutilizables (principio DRY) ----
log()       { echo "[\$(\$DATE '+%Y-%m-%d %H:%M:%S')] [\$1] \$2"; }
log_info()  { log "INFO"  "\$1"; }
log_error() { log "ERROR" "\$1"; }

# ---- Limpieza ante fallos (trap) ----
COMPLETADO=0
limpiar() {
    local codigo=\$?
    if [[ -d "\$TMP_DIR" ]]; then
        \$RM -rf "\$TMP_DIR"
        log_info "Temporales eliminados: \$TMP_DIR"
    fi
    if (( COMPLETADO == 0 )); then
        if [[ -f "\$PAQUETE" ]]; then
            \$RM -f "\$PAQUETE"
            log_error "Paquete incompleto eliminado: \$PAQUETE"
        fi
        log_error "===== Respaldo FALLIDO (codigo \$codigo) ====="
    fi
}
trap limpiar EXIT
trap 'log_error "Interrupcion imprevista (senal recibida)"; exit 130' INT TERM HUP
trap 'log_error "Fallo en la linea \$LINENO: \$BASH_COMMAND"' ERR

# ---- 1. Extraccion ----
log_info "===== Inicio de respaldo \${FECHA} ====="
\$MKDIR -p "\$TMP_DIR"
log_info "mongodump de la base '\${DB_NOMBRE}'"
\$MONGODUMP --db "\$DB_NOMBRE" --out "\${TMP_DIR}/mongo" --quiet
log_info "Dump generado en \${TMP_DIR}/mongo"

if [[ -n "\${PAUSA_DEMO:-}" ]]; then
    log_info "PAUSA_DEMO: esperando \${PAUSA_DEMO}s (Ctrl+C para probar el trap)"
    \$SLEEP "\$PAUSA_DEMO"
fi

# ---- 2. Empaquetado (dump + codigo fuente + configuracion) ----
log_info "Empaquetando dump + \${APP_PADRE}/\${APP_NOMBRE}"
\$TAR --exclude="\${APP_NOMBRE}/node_modules" -czf "\$PAQUETE" \\
     -C "\$TMP_DIR" mongo \\
     -C "\$APP_PADRE" "\$APP_NOMBRE"
log_info "Paquete creado: \$PAQUETE (\$(\$DU -h "\$PAQUETE" | \$CUT -f1))"

# ---- 3. Transferencia eficiente con rsync sobre SSH ----
log_info "rsync hacia \${DESTINO_USUARIO}@\${DESTINO_HOST}:\${DESTINO_DIR}/"
\$RSYNC -az --partial \\
    -e "\$SSH -o BatchMode=yes -o ConnectTimeout=10" \\
    "\$PAQUETE" "\${DESTINO_USUARIO}@\${DESTINO_HOST}:\${DESTINO_DIR}/"
log_info "Transferencia completada"

# ---- 4. Retencion local (conserva los ultimos \${RETENCION_LOCAL}) ----
\$LS -1t "\$LOCAL_DIR"/backup_*.tar.gz | \$TAIL -n +\$((RETENCION_LOCAL + 1)) | \$XARGS -r \$RM -f

COMPLETADO=1
log_info "===== Respaldo completado con exito ====="
EOF_BAK
    chown student:student /opt/cronos/cronos_backup.sh
    chmod 700 /opt/cronos/cronos_backup.sh
    git_versionar /opt/cronos student "Version inicial de cronos_backup.sh"

    titulo "6/8 Programacion en cron (student, todas las noches 02:00)"
    ( crontab -u student -l 2>/dev/null | grep -v cronos_backup || true
      echo "0 2 * * * /opt/cronos/cronos_backup.sh vm-destino" ) | crontab -u student -
    crontab -u student -l

    titulo "7/8 Llave SSH hacia vm-destino"
    if [[ ! -f /home/student/.ssh/id_ed25519 ]]; then
        sudo -u student mkdir -p /home/student/.ssh
        sudo -u student ssh-keygen -q -t ed25519 -N "" -f /home/student/.ssh/id_ed25519
    fi
    echo
    echo ">>> Ahora te pide la contrasena de student en vm-destino. Escribe: student"
    echo
    sudo -u student ssh-copy-id -o StrictHostKeyChecking=accept-new -i /home/student/.ssh/id_ed25519.pub student@vm-destino

    titulo "8/8 Prueba del respaldo"
    sudo -u student /opt/cronos/cronos_backup.sh vm-destino || true
    tail -n 12 /var/log/cronos_backup.log
    echo
    echo "Respaldos en vm-destino:"
    sudo -u student ssh -o BatchMode=yes student@vm-destino 'ls -lh /home/student/respaldos'

    titulo "LISTO: vm-origen"
}

case "$MODO" in
    destino) setup_destino ;;
    origen)  setup_origen "$@" ;;
    *) echo "Uso: sudo bash a15.sh destino | sudo bash a15.sh origen <IP_DESTINO>"; exit 1 ;;
esac
