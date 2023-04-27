#!/usr/bin/env bash
## start-build-dependency.sh  
## arg 1: wheather to build solana-mango-simulator
## arg 2: ARTIFACT BUCKET
## arg 3: NAME OF ENV ARTIFACT FILE
## env
set -ex
## fiunctions
## s1: bucket name s2: file name s3: local directory
download_file() {
	for retry in 0 1 2
	do
		if [[ $retry -gt 2 ]];then
			break
		fi
		gsutil cp "$1/$2" "$3"
		if [[ ! -f "$2" ]];then
			echo NO "$2" found, retry
		else
            echo "$2" dowloaded
			break
		fi
        sleep 5
	done
}
# s1: local file s2: bucket name
upload_file() {
	gsutil cp  "$1" "$2"
}

## Download key files from gsutil
if [[ "$1" != "true" && "$1" != "false" ]];then 
	build_binary="false"
else
	build_binary="$1"
fi
[[ ! "$2" ]]&& echo "No artifact bucket" && exit 1
[[ ! "$3" ]]&& echo "No artifact filename" && exit 1
download_file "gs://$2" "$3" "$HOME"
sleep 5
[[ ! -f "env-artifact.sh" ]] && echo no "env-artifact.sh" downloaded && exit 2
# shellcheck source=/dev/null
source $HOME/.profile
source $HOME/env-artifact.sh

## preventing lock-file build fail, 
## also need to disable software upgrade in image
sudo fuser -vki -TERM /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend || true
sudo dpkg --configure -a
sudo apt update
## pre-install and rust version
sudo apt-get install -y libssl-dev libudev-dev pkg-config zlib1g-dev llvm clang cmake make libprotobuf-dev protobuf-compiler
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g typescript
sudo npm install -g ts-node
sudo npm install -g yarn
# warning package-lock.json found. 
# Your project contains lock files generated by tools other than Yarn. 
# It is advised not to mix package managers in order to avoid resolution inconsistencies caused by unsynchronized lock files.
# To clear this warning, remove package-lock.json.
# Memo by author: use yarn instead of npm install
rm -f package-lock.json || true
yarn install
rustup default stable
rustup update

echo ------- stage: git clone repos ------
cd $HOME
[[ -d "$GIT_REPO_DIR" ]]&& rm -rf $GIT_REPO_DIR
git clone "$GIT_REPO"
cd $GIT_REPO_DIR
git checkout "$BUILDKITE_BRANCH"
cd $HOME
[[ -d "$HOME/$MANGO_CONFIGURE_DIR" ]]&& rm -rf "$HOME/$MANGO_CONFIGURE_DIR"
git clone "$MANGO_CONFIGURE_REPO" # may remove later
[[ -d "$HOME/$MANGO_SIMULATION_DIR" ]]&& rm -rf "$HOME/$MANGO_SIMULATION_DIR"
git clone "$MANGO_SIMULATION_REPO" "$HOME/$MANGO_SIMULATION_DIR"

echo ------- stage: build or download mango-simulation ------
# clone mango_bencher and mkdir dep dir
cd "$HOME/$MANGO_SIMULATION_DIR"
if  [[ "$build_binary" == "true" ]];then
    git checkout "$MANGO_SIMULATION_BRANCH"
	cargo build --release
	cp "$HOME/$MANGO_SIMULATION_DIR/target/release/mango-simulation" $HOME
	chmod +x $HOME/mango-simulation
	upload_file $HOME/mango-simulation "gs://$ARTIFACT_BUCKET/$BUILDKITE_PIPELINE_ID/$BUILDKITE_BUILD_ID/$BUILDKITE_JOB_ID/$MANGO_SIMULATION_ARTIFACT_FILE"
else
	# download from bucket
	cd $HOME
	download_file "gs://$ARTIFACT_BUCKET/$BUILDKITE_PIPELINE_ID/$BUILDKITE_BUILD_ID/$BUILDKITE_JOB_ID" "$MANGO_SIMULATION_ARTIFACT_FILE" "$HOME"
	[[ ! -f "$HOME/mango-simulation" ]] && echo no mango-simulation downloaded && exit 1
	chmod +x $HOME/mango-simulation
	echo mango-simuation downloaded
fi
echo ---- stage: copy files to HOME and mkdir log folder ----
cp "$HOME/$GIT_REPO_DIR/start-dos-test.sh" /home/sol/start-dos-test.sh
cp "$HOME/$GIT_REPO_DIR/start-upload-logs.sh" /home/sol/start-upload-logs.sh
[[ -d "$HOME/$HOSTNAME" ]] && rm -rf "$HOME/$HOSTNAME"
mkdir -p "$HOME/$HOSTNAME"

echo ---- stage: download id, accounts and authority file in HOME ----
cd $HOME
download_file "gs://$MANGO_SIMULATION_PRIVATE_BUCKET" "$ID_FILE" "$HOME"
[[ ! -f "$ID_FILE" ]]&&echo no "$ID_FILE" file && exit 1
download_file "gs://$MANGO_SIMULATION_PRIVATE_BUCKET" "$AUTHORITY_FILE" "$HOME"
[[ ! -f "$AUTHORITY_FILE" ]]&&echo no "$AUTHORITY_FILE" file && exit 1
download_accounts=( $ACCOUNTS )
for acct in "${download_accounts[@]}"
do
  download_file "gs://$MANGO_SIMULATION_PRIVATE_BUCKET" "$acct" "$HOME"
  [[ ! -f "$acct" ]]&& echo no "$acct" file && exit 1 || echo "$acct" downloaded
done

echo --- stage: Start refunding clients accounts
cd "$MANGO_CONFIGURE_DIR"
for acct in "${download_accounts[@]}"
do
  ts-node refund_users.ts "${HOME}/$acct" > out.log 2>1 || true
  if [ "$?" -ne 0 ]; then
    echo --- refund failed for $acct
  fi
done
exit 0


