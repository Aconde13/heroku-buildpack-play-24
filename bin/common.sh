#!/usr/bin/env bash

# Forzar uso de curl del sistema y agregar debug
set -e
export PATH="/usr/bin:/bin:$PATH"
CURL="/usr/bin/curl"
echo "Using curl at: $(command -v curl)"
$CURL --version || true

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

get_play_version() {
  local file=${1?"No file specified"}
  if [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  grep -P '.*-.*play[ \t]+[0-9\.]+' "$file" | sed -E -e 's/[ \t]*-[ \t]*play[ \t]+([0-9A-Za-z\.]*).*/\1/'
}

check_compile_status() {
  if [ "${PIPESTATUS[*]}" != "0 0" ]; then
    echo " !     Failed to build Play! application"
    rm -rf "$CACHE_DIR/$PLAY_PATH"
    echo " !     Cleared Play! framework from cache"
    exit 1
  fi
}

download_play_official() {
  local playVersion=${1}
  local playTarFile=${2}

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
  local playUnzipDir="tmp-play-unzipped/"
  mkdir -p ${playUnzipDir}
  
  echo "Zip file: $playZipFile"
  if [ ! -f ${playZipFile} ]; then
    echo "Error: Zip file not found."
    exit 1
  fi
  
  unzip ${playZipFile} -d ${playUnzipDir} > /dev/null 2>&1

  PLAY_BUILD_DIR=$(find ${playUnzipDir} -name 'framework' -type d | sed 's/framework//')

  # Crear estructura de .play
  mkdir -p .play/framework/src/play
  mkdir -p .play/framework/pym
  mkdir -p .play/modules
  mkdir -p .play/resources

  cp -r "$PLAY_BUILD_DIR/framework/dependencies.yml" .play/framework
  cp -r "$PLAY_BUILD_DIR/framework/lib/" .play/framework
  cp -r "$PLAY_BUILD_DIR/framework/play-"*.jar .play/framework
  cp -r "$PLAY_BUILD_DIR/framework/pym/" .play/framework
  cp -r "$PLAY_BUILD_DIR/framework/src/play/version" .play/framework/src/play
  cp -r "$PLAY_BUILD_DIR/framework/templates/" .play/framework

  cp -r "$PLAY_BUILD_DIR/modules" .play
  cp -r "$PLAY_BUILD_DIR/play" .play
  cp -r "$PLAY_BUILD_DIR/resources" .play

  chmod +x .play/play
}

validate_play_version() {
  local playVersion=${1}
  if [ "$playVersion" == "1.4.0" ] || [ "$playVersion" == "1.3.2" ]; then
    echo "Unsupported version: $playVersion"
    echo "This version of Play! is incompatible with Linux. Upgrade to a newer version."
    exit 1
  elif [[ "$playVersion" =~ ^2.* ]]; then
    echo "Unsupported version: Play 2.x requires the Scala buildpack"
    exit 1
  fi
}

install_openjdk() {
  local java_version=$1
  local build_dir=$2
  local bin_dir=$3

  echo "Installing OpenJDK version $java_version..."

  JDK_DIR="$build_dir/.jdk"
  mkdir -p "$JDK_DIR"

  if [[ "$java_version" == "1.8" || "$java_version" == "8" ]]; then
    JDK_URL="https://github.com/Cliengo/heroku-buildpack-play-24/releases/download/heroku-24/jre-8u431-linux-x64.tar.gz"
  else
    echo "Unsupported Java version $java_version"
    exit 1
  fi

  echo "Downloading JDK from: $JDK_URL"
  $CURL -sS -L --fail "$JDK_URL" | tar xz -C "$JDK_DIR" --strip-components=1
  echo "OpenJDK installed to $JDK_DIR"
}

install_play() {
  VER_TO_INSTALL=$1
  if [ -z "$VER_TO_INSTALL" ]; then
    echo "ERROR: VER_TO_INSTALL vacío, no se puede instalar Play!"
    exit 1
  fi

  PLAY_URL="https://s3.amazonaws.com/heroku-jvm-langpack-play/play-heroku-$VER_TO_INSTALL.tar.gz"
  PLAY_TAR_FILE="play-heroku.tar.gz"

  validate_play_version "$VER_TO_INSTALL"

  echo "-----> Installing Play! $VER_TO_INSTALL....."

  status=$($CURL --retry 3 --silent --head -L -w "%{http_code}" -o /dev/null "$PLAY_URL")

  if [ "$status" != "200" ]; then
    download_play_official "$VER_TO_INSTALL" "$PLAY_TAR_FILE"
  else
    $CURL --retry 3 -sS --max-time 150 -L --fail "$PLAY_URL" -o "$PLAY_TAR_FILE"
  fi

  if [ ! -f "$PLAY_TAR_FILE" ]; then
    echo "-----> Error downloading Play! framework. Please try again..."
    exit 1
  fi

  if ! file "$PLAY_TAR_FILE" | grep -q gzip; then
    echo "Failed to install Play! framework or unsupported Play! framework version specified."
    exit 1
  fi

  tar xzmf "$PLAY_TAR_FILE"
  rm "$PLAY_TAR_FILE"
  chmod +x "$PLAY_PATH/play"
  echo "Done installing Play!" | indent
}

remove_play() {
  local build_dir=$1
  local play_version=$2

  rm -rf "${build_dir}/tmp-play-unzipped"
  rm -f "${build_dir}/play-${play_version}.zip"
}
