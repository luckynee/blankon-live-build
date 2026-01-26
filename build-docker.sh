#!/bin/bash

# Load configuration from .env file
if [ -f .env ]; then
  source .env
fi

if [ -z "$TELEGRAM_BOT_KEY" ]; then
  echo "Error: TELEGRAM_BOT_KEY is missing. Please check your .env file."
  exit 1
fi

## Default messages
RESULT="gagal terbit ❌"
ACTION="Log build dapat disimak"

## Args
REPO=$1
BRANCH=$2
REPO_NAME=$(echo "$REPO" | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?|\1|')
# Optional
COMMIT=$3
ARCH=amd64

START=$(date +%s)

# Cleanup previous builds
echo "Cleaning up..."
sudo umount $(mount | grep live-build | cut -d ' ' -f 3) || true
sudo rm -rf ./chroot ./local ./cache ./build ./tmp || true

## Case 1: Local Build (No params)
if [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
  echo "Running LOCAL build..."
  sudo lb clean --purge
  sudo lb config --architectures $ARCH
  sudo time lb build 2>&1 | sudo tee blankon-docker-image-$ARCH.build.log
  
  LOG_FILE="blankon-docker-image-$ARCH.build.log"
  
  # Check success
  if tail -n 10 "$LOG_FILE" | grep -q "P: Build completed successfully"; then
    echo "Build Success! ✅"
    TARBALL=$(ls *.tar.xz 2>/dev/null || ls *.tar.gz 2>/dev/null || ls *.tar 2>/dev/null | head -n 1)
    if [ -n "$TARBALL" ]; then
        echo "Generated artifact: $TARBALL"
        sha256sum "$TARBALL" > "$TARBALL.sha256sum"
        echo "To import into Docker run:"
        echo "  docker import $TARBALL blankon:latest"
    fi
  else
    echo "Build Failed! ❌"
    exit 1
  fi
  
  exit 0
fi

## Case 2: Production/Remote Build (Params provided)
echo "Running PRODUCTION build for $REPO $BRANCH $COMMIT ..."

## Config for production paths
JAHITAN_PATH=${JAHITAN_PATH:-/home/user/jahitan-harian} # Use env var or default
TODAY=$(date '+%Y%m%d')
# Ensure dir exists to avoid errors if not on the production server
mkdir -p $JAHITAN_PATH 
TODAY_COUNT=$(ls $JAHITAN_PATH | grep $TODAY | wc -l)
TODAY_COUNT=$(($TODAY_COUNT + 1))
TARGET_DIR=$JAHITAN_PATH/$TODAY-$TODAY_COUNT

mkdir -p $TARGET_DIR
sudo mkdir -p tmp || true
sudo chmod -R a+rw tmp

## Preparation
echo "Cloning repository..."
git clone -b $BRANCH $REPO ./tmp/$TODAY-$TODAY_COUNT

# Checkout specific commit if provided
if [ -n "$COMMIT" ]; then
     git -C ./tmp/$TODAY-$TODAY_COUNT checkout $COMMIT
fi
COMMIT=$(git -C ./tmp/$TODAY-$TODAY_COUNT rev-parse --short HEAD)
CLEAN_REPO_URL=$(echo "$REPO" | sed 's/\.git$//')
COMMIT_URL="$CLEAN_REPO_URL/commit/$COMMIT"

# Setup config
sudo rm -rf config
cp -vR ./tmp/$TODAY-$TODAY_COUNT/config config

## Build
sudo lb clean
sudo lb config --architectures $ARCH
rm -f blankon-docker-image-$ARCH.build.log

# Run stages manually to avoid binary stage failures
{
    sudo lb bootstrap
    sudo lb chroot
} 2>&1 | tee blankon-docker-image-$ARCH.build.log

# Manually create the Docker tarball from the chroot
if [ -d "chroot/bin" ]; then
    echo "Filesystem built. Creating Docker tarball..."
    sudo tar -C chroot -c . | xz > blankon-live-image-$ARCH.tar.xz
    echo "P: Build completed successfully" >> blankon-docker-image-$ARCH.build.log
else
    echo "E: Chroot failed" >> blankon-docker-image-$ARCH.build.log
fi


LOG_FILE="blankon-docker-image-$ARCH.build.log"

if tail -n 10 "$LOG_FILE" | grep -q "P: Build completed successfully"; then
  RESULT="telah terbit ✅"
  ACTION="Berkas citra docker dapat diunduh"

  # Identify output
  TARBALL=$(ls *.tar.xz 2>/dev/null || ls *.tar.gz 2>/dev/null || ls *.tar 2>/dev/null | head -n 1)

  if [ -n "$TARBALL" ]; then
      cp -v "$TARBALL" "$TARGET_DIR/$TARBALL"
      sha256sum "$TARGET_DIR/$TARBALL" > "$TARGET_DIR/$TARBALL.sha256sum"

      # Copy other metadata if needed
      cp -v blankon-live-image-$ARCH.packages "$TARGET_DIR/" 2>/dev/null || true

      # Update 'current' link
      rm -f "$JAHITAN_PATH/current"
      ln -s "$TARGET_DIR" "$JAHITAN_PATH/current"
      echo "$TODAY-$TODAY_COUNT" > "$JAHITAN_PATH/current/current.txt"

      echo "Artifacts saved to $TARGET_DIR"

      if [ -x ./upload-docker.sh ]; then
          if ! ./upload-docker.sh "$TARBALL" "$CLEAN_REPO_URL" "$BRANCH" "$COMMIT"; then
              echo "Warning: GHCR upload failed."
          fi
      else
          echo "Warning: ./upload-docker.sh is missing or not executable."
      fi
  else
       echo "Error: Output tarball not found."
  fi
else
   echo "Build Failed! ❌"
fi

END=$(date +%s)
DURATION=$((END - START))
TOTAL_DURATION="Done in $(date -d@$DURATION -u +%H:%M:%S)."
echo $TOTAL_DURATION
echo $TOTAL_DURATION >> "$LOG_FILE"
tail -n 100 "$LOG_FILE" > "$TARGET_DIR/blankon-docker-image-$ARCH.tail100.build.log.txt"
cp -v "$LOG_FILE" "$TARGET_DIR/blankon-docker-image-$ARCH.build.log.txt"

# Cleanup
sudo umount $(mount | grep live-build | cut -d ' ' -f 3) || true

# Telegram Notification
curl -X POST -H 'Content-Type: application/json' -d "{\"chat_id\": \"-1001067745576\", \"message_thread_id\": \"51909\", \"parse_mode\": \"HTML\", \"disable_web_page_preview\": true, \"text\": \"Jahitan harian Docker $TODAY-$TODAY_COUNT [ revisi <a href=\\\"$COMMIT_URL\\\">$COMMIT</a> ] dari $REPO_NAME cabang $BRANCH $RESULT. $ACTION di http://jahitan.blankonlinux.id/$TODAY-$TODAY_COUNT/\", \"disable_notification\": true}" https://api.telegram.org/bot$TELEGRAM_BOT_KEY/sendMessage
