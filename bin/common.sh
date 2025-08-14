#!/usr/bin/env bash
set -e

# --- Forzar el curl del sistema y agregar debug útil ---
export PATH="/usr/bin:/bin:$PATH"
CURL="/usr/bin/curl"
echo "Using curl at: $(command -v curl)"
$CURL --version || true

# ========== Utilidades generales ==========
indent() {
  while IFS= read -r line; do
    printf '       %s\n' "$line"
  done
}

export_env_dir() {
  env_dir=$1
  whitelist_regex=${2:-''}
  blacklist_regex=${3:-'^(PATH|GIT_DIR|CPATH|CPPATH|LD_PRELOAD|LIBRARY_PATH|JAVA_OPTS)$'}
  if [ -d "$env_dir" ]; then
    for e in $(ls "$env_dir"); do
      echo "$e" | grep -E "$whitelist_regex" | grep -qvE "$blacklist_regex" &&
      export "$e=$(cat "$env_dir/$e")"
    done
  fi
}

# Devuelve solo el número de versión (e.g., 1.8.0) desde conf/dependencies.yml
get_play_version() {
  local file=${1?"No file specified"}
  if [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  # Línea que empieza con "- play <version>", quitar comentarios y CR, y extraer el segundo campo
  grep -iE '^[[:space:]]*-[[:space:]]+play[[:space:]]+[0-9A-Za-z\.\-]+' "$file" \
    | head -1 \
    | sed 's/#.*//' \
    | tr -d '\r' \
    | awk '{print $3}'
}

# Verifica el estatus de un pipeline "cmd | sed" (usado en compile)
check_compile_status() {
  local arr=("${PIPESTATUS[@]}")
  for s in "${arr[@]}"; do
    if [ "$s" != "0" ]; then
      echo " !     Failed to build Play! application"
      exit 1
    fi
  done
}

validate_play_version() {
  local playVersion=${1}
  if [ "$playVersion" = "1.4.0" ] || [ "$playVersion" = "1.3.2" ]; then
    echo "Unsupported version: $playVersion (incompatible con Linux)."
    exit 1
  elif [[ "$playVersion" =~ ^2.* ]]; then
    echo "Unsupported version: Play 2.x requiere el Scala buildpack."
    exit 1
  fi
}

# ========== Java / JDK ==========
# Firma esperada por compile: install_openjdk "1.8" "$BUILD_DIR" "$BIN_DIR"
install_openjdk() {
  local java_version="$1"
  local build_dir="$2"
  local bin_dir="$3"

  echo "Installing OpenJDK version ${java_version}..."

  local JDK_DIR="${build_dir}/.jdk"
  mkdir -p "${JDK_DIR}"

  # Construir URL si no está definida externamente
  local JDK_URL_LOCAL=""
  if [[ "$java_version" == "1.8" || "$java_version" == "8" ]]; then
    # Default probado en tu fork (JRE 8u431)
    JDK_URL_LOCAL="https://github.com/Cliengo/heroku-buildpack-play-24/releases/download/heroku-24/jre-8u431-linux-x64.tar.gz"
  else
    echo "Unsupported Java version ${java_version}"
    exit 1
  fi

  # Permitir override si alguien exportó JDK_URL antes de llamar
  local EFFECTIVE_JDK_URL="${JDK_URL:-$JDK_URL_LOCAL}"

  echo "Downloading JDK from: ${EFFECTIVE_JDK_URL}"
  $CURL -sS -L --fail "${EFFECTIVE_JDK_URL}" | tar xz -C "${JDK_DIR}" --strip-components=1
  echo "OpenJDK installed to ${JDK_DIR}"
}

# ========== Play! framework ==========
# Descarga oficial de Play 1.x desde GitHub Releases
download_play_official() {
  local playVersion=${1}
  local playTarget=${2}   # no se usa como archivo, mantenido por compatibilidad

  if [ -z "$playVersion" ]; then
    echo "ERROR: playVersion vacío, no se puede descargar Play!"
    exit 1
  fi

  local playZipFile="play-${playVersion}.zip"
  local playUrl="https://github.com/Cliengo/heroku-buildpack-play-24/releases/download/heroku-24/play-1.4.5.zip"

  if [[ "$playVersion" > "1.6.0" ]]; then
    playUrl="https://github.com/playframework/play1/releases/download/${playVersion}/${playZipFile}"
  fi

  echo "Downloading Play! from: ${playUrl}"
  $CURL --retry 3 -sS -O -L --fail "${playUrl}"

  echo "Preparing binary package..."
  local playUnzipDir="tmp-play-unzipped"
  mkdir -p "${playUnzipDir}"

  echo "Zip file: ${playZipFile}"
  if [ ! -f "${playZipFile}" ]; then
    echo "Error: Zip file not found."
    exit 1
  fi

  unzip -q "${playZipFile}" -d "${playUnzipDir}"

  # Buscar el directorio raíz del zip (donde vive 'framework')
  local PLAY_BUILD_DIR
  PLAY_BUILD_DIR=$(find "${playUnzipDir}" -type d -name 'framework' | head -1 | sed 's#/framework##')
  if [ -z "${PLAY_BUILD_DIR}" ]; then
    echo "Error: no se encontró el directorio 'framework' dentro del zip."
    exit 1
  fi

  # Crear estructura final
  mkdir -p .play/framework/src/play .play/framework/pym .play/modules .play/resources

  cp -r "${PLAY_BUILD_DIR}/framework/dependencies.yml"       .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/lib/"                   .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/play-"*.jar             .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/pym/"                   .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/src/play/version"       .play/framework/src/play
  cp -r "${PLAY_BUILD_DIR}/framework/templates/"             .play/framework

  cp -r "${PLAY_BUILD_DIR}/modules"   .play
  cp -r "${PLAY_BUILD_DIR}/play"      .play
  cp -r "${PLAY_BUILD_DIR}/resources" .play

  chmod +x .play/play
}

install_play() {
  local VER_TO_INSTALL="$1"
  if [ -z "$VER_TO_INSTALL" ]; then
    echo "ERROR: VER_TO_INSTALL vacío, no se puede instalar Play!"
    exit 1
  fi

  local PLAY_URL="https://s3.amazonaws.com/heroku-jvm-langpack-play/play-heroku-${VER_TO_INSTALL}.tar.gz"
  local PLAY_TAR_FILE="play-heroku.tar.gz"

  validate_play_version "$VER_TO_INSTALL"
  echo "-----> Installing Play! ${VER_TO_INSTALL}....."

  local status
  status=$($CURL --retry 3 --silent --head -L -w "%{http_code}" -o /dev/null "${PLAY_URL}")

  if [ "$status" != "200" ]; then
    # Fallback: descargar el zip oficial y ensamblar .play/
    download_play_official "$VER_TO_INSTALL" "$PLAY_TAR_FILE"
  else
    $CURL --retry 3 -sS --max-time 150 -L --fail "${PLAY_URL}" -o "${PLAY_TAR_FILE}"
    if ! file "${PLAY_TAR_FILE}" | grep -q gzip; then
      echo "Failed to install Play! framework or unsupported Play! framework version specified."
      exit 1
    fi
    tar xzmf "${PLAY_TAR_FILE}"
    rm -f "${PLAY_TAR_FILE}"
    chmod +x ".play/play"
  fi

  echo "Done installing Play!" | indent
}

remove_play() {
  local build_dir=$1
  local play_version=$2
  rm -rf "${build_dir}/tmp-play-unzipped"
  rm -f "${build_dir}/play-${play_version}.zip"
}
