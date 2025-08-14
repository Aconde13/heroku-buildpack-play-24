#!/usr/bin/env bash
set -e
export PATH="/usr/bin:/bin:$PATH"
CURL="/usr/bin/curl"
echo "Using curl at: $(command -v curl)"
$CURL --version || true

download_play_official() {
  local playVersion=${1}
  local playTarFile=${2}
  local playZipFile="play-${playVersion}.zip"
  local playUrl="https://github.com/Cliengo/heroku-buildpack-play-24/releases/download/heroku-24/play-1.4.5.zip"

  if [[ "$playVersion" > "1.6.0" ]]; then
    playUrl="https://github.com/playframework/play1/releases/download/${playVersion}/${playZipFile}"
  fi

  echo "Downloading Play! from: ${playUrl}"
  $CURL --retry 3 -sS -O -L --fail "${playUrl}"

  echo "Preparing binary package..."
  local playUnzipDir="tmp-play-unzipped/"
  mkdir -p "${playUnzipDir}"

  echo "Zip file: ${playZipFile}"
  if [ ! -f "${playZipFile}" ]; then
    echo "Error: Zip file not found."
    exit 1
  fi

  unzip "${playZipFile}" -d "${playUnzipDir}" > /dev/null 2>&1
  PLAY_BUILD_DIR=$(find "${playUnzipDir}" -name 'framework' -type d | sed 's/framework//')

  mkdir -p .play/framework/src/play .play/framework/pym .play/modules .play/resources

  cp -r "${PLAY_BUILD_DIR}/framework/dependencies.yml"   .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/lib/"               .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/play-"*.jar         .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/pym/"               .play/framework
  cp -r "${PLAY_BUILD_DIR}/framework/src/play/version"   .play/framework/src/play
  cp -r "${PLAY_BUILD_DIR}/framework/templates/"         .play/framework

  cp -r "${PLAY_BUILD_DIR}/modules"   .play
  cp -r "${PLAY_BUILD_DIR}/play"      .play
  cp -r "${PLAY_BUILD_DIR}/resources" .play

  chmod +x .play/play
}

install_openjdk() {
  echo "Downloading JDK from: ${JDK_URL}"
  $CURL -sS -L --fail "${JDK_URL}" | tar xz -C "${JDK_DIR}" --strip-components=1
  echo "OpenJDK installed to $JDK_DIR"
}
