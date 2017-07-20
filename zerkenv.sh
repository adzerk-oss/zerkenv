#!/bin/sh

# Sourcing this script in fish shell requires `bass`, which hides STDOUT until
# after the process has completed. This is an interactive script, so we don't
# want that. Using STDERR for interactive prompts, etc. which is a recommended
# Unix practice anyway.
function errcho() {
  >&2 echo $@
}

function errcat() {
  >&2 cat $@
}

_mktemp() {
  case $(uname -s) in
    Darwin) mktemp -t temp ;;
    Linux) mktemp ;;
    *) (errcho "Unknown system '$(uname -s)', don't now how to _mktemp");
       return 1 ;;
  esac
}

assert_has_command() {
  if [[ -z "$(which $1)" ]]; then
    echo "$1 is required by this script and is not installed."
    exit 1
  fi
}

assert_has_command aws

################################################################################

s3_bucket=${ZERKENV_BUCKET-zerkenv}

# Fetches modules from S3, as well as their dependency modules, and builds a
# single script that is the concatenation of all of the module scripts.
#
# $1: the file to which to append the script
# $2: a comma-separated string of modules, e.g. foo,bar,baz
# $3: a file containing the list of modules that have been sourced so far
function build_script() {
  local script="$1"
  # Convert the comma-separated string (list of modules) into an array.
  local modules=""
  IFS=',' modules=($2)
  local sourced_modules="$3"

  for m in "${modules[@]}"; do
    local module="$m"
    # If the module has any dependencies, source them first.
    local deps_file=$(_mktemp)
    local s3_deps_file="s3://$s3_bucket/$module.deps"
    aws s3 cp "$s3_deps_file" "$deps_file" >/dev/null 2>/dev/null
    if [[ $? -eq 0 ]]; then
      build_script "$script" "$(cat $deps_file)" "$sourced_modules"
    fi

    # Source the module if it hasn't already been sourced.
    grep -x "$module" "$sourced_modules" >/dev/null
    if [[ $? -ne 0 ]]; then
      # Download script from S3 into a temp file.
      local s3_file="s3://$s3_bucket/$module.sh"
      local file=$(_mktemp)

      errcho "-- Downloading $s3_file..."
      aws s3 cp "$s3_file" "$file" >&2

      # Discard shebang lines and append to script.
      grep -vhe '^#!' "$file" >> "$script"

      # Note that the module has been sourced.
      echo "$module" >> "$sourced_modules"
    fi
  done
}

# Given a comma-separated string representing a list of modules to source,
# builds a script that is the concatenation of each of the module scripts,
# including their dependency modules, and sources the script.
function source_modules() {
  local modules="$1"
  local script=$(_mktemp)
  echo "#!/bin/sh" > "$script"
  local sourced_modules=$(_mktemp)

  build_script "$script" "$modules" "$sourced_modules"

  errcho
  errcho "-----"
  errcat "$script"
  errcho "-----"
  errcho
  errcho "-----"
  errcho "Press ENTER to run this script, or ^C to cancel."
  errcho "-----"
  errcho
  read

  . "$script"
}

# Given a filename like `foo.sh` or `foo.deps`, downloads it from S3 and prints
# its contents to STDOUT.
function download_file() {
  local filename="$1"
  local s3_file="s3://$s3_bucket/$filename"
  local file=$(_mktemp)

  errcho "-- Downloading $s3_file..."
  aws s3 cp "$s3_file" "$file" >&2

  cat "$file"
  return 0
}

# Given some content from STDIN and a filename argument, uploads a file to S3
# with the filename and content.
function upload_file() {
  local filename="$1"
  local file=$(_mktemp)
  cat > $file
  local s3_file="s3://$s3_bucket/$filename"

  errcho "-- Uploading => $s3_file..."
  aws s3 cp "$file" "$s3_file" >&2
  errcho "-- Done."

  return 0
}

################################################################################

usage="Usage: zerkenv [ -h|--help | -s|--source m1,m2,m3,... | -d|--download m1 | -u|--upload m1 ]"

# Have to null these out up here because we are sourcing the file and don't want
# them to still have the value from the last time the file was sourced.
source_modules=""
download_file=""
upload_file=""

while [[ "$1" != "" ]]; do
   case "$1" in
       "--help" | "-h")
         echo "$usage"
         return 0
         ;;
       "--source" | "-s")
         shift
         source_modules="$1"
         ;;
       "--download" | "-d")
         shift
         download_file="$1"
         ;;
       "--upload" | "-u")
         shift
         upload_file="$1"
         ;;
   esac
   shift
done

if [[ -n "$source_modules" ]]; then
  source_modules "$source_modules"
elif [[ -n "$download_file" ]]; then
  download_file "$download_file"
elif [[ -n "$upload_file" ]]; then
  cat | upload_file "$upload_file"
else
  echo "$usage"
  return 0
fi

