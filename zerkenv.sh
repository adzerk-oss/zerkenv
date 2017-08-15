#!/bin/sh

# Sourcing this script in fish shell requires `bass`, which hides STDOUT until
# after the process has completed. This is an interactive script, so we don't
# want that. Using STDERR for interactive prompts, etc. which is a recommended
# Unix practice anyway.
function errcho() {
  >&2 echo $@
}
export -f errcho

function errcat() {
  >&2 cat $@
}
export -f errcat

_mktemp() {
  case $(uname -s) in
    Darwin) mktemp -t temp ;;
    Linux) mktemp ;;
    *) (errcho "Unknown system '$(uname -s)', don't now how to _mktemp");
       return 1 ;;
  esac
}
export -f _mktemp

assert_has_command() {
  if [[ -z "$(which $1)" ]]; then
    echo "$1 is required by this script and is not installed."
    exit 1
  fi
}

assert_has_command aws
assert_has_command parallel

################################################################################

if [[ -z "$ZERKENV_BUCKET" ]]; then
  errcho "Please set ZERKENV_BUCKET to the name of an S3 bucket."
  return 0
fi

# For each module in $1 (a multiline string containing a list of module names,
# one per line), adds the module to the set of loaded modules stored in the
# ZERKENV_MODULES environment variable.
function add_to_loaded_modules() {
  local modules="$1"

  while read module; do
    # Check to see if the module is already in the set.
    echo -e "$ZERKENV_MODULES" | grep -x "$module" >/dev/null

    # If it isn't, add it.
    if [[ $? -ne 0 ]]; then
      if [[ -z "$ZERKENV_MODULES" ]]; then
        export ZERKENV_MODULES="$module"
      else
        export ZERKENV_MODULES=$(echo -e "$ZERKENV_MODULES\n$module")
      fi
    fi
  done < <(echo -e "$modules")
}

# Given one module, fetches the module's dependency list from S3 and prints it
# to STDOUT, one module per line.
function resolve_deps() {
  local module="$1"

  local deps_file=$(_mktemp)
  local s3_deps_file="s3://$ZERKENV_BUCKET/$module.deps"
  aws s3 cp "$s3_deps_file" "$deps_file" >/dev/null 2>/dev/null

  if [[ $? -eq 0 ]]; then
    # Convert comma-separated list into an array.
    local deps=""
    IFS=',' deps=($(cat $deps_file))
    # Convert array into a file.
    local f=$(_mktemp)
    for dep in "${deps[@]}"; do
      echo "$dep" >> "$f"
    done
    parallel -a "$f" -k resolve_deps
  fi
  errcho "- $module"
  echo "$module"
}
export -f resolve_deps

# Given a comma-separated string of modules, fetches the modules' dependency
# lists from S3 and prints them to STDOUT, one module per line.
function resolve_all_deps() {
  errcho "Resolving module dependencies..."

  # Convert the comma-separated string (list of modules) into an array.
  local modules=""
  IFS=',' modules=($1)

  # Convert the array into a multiline file.
  local f=$(_mktemp)
  for m in "${modules[@]}"; do
    echo "$m" >> "$f"
  done

  # the awk voodoo here is like `uniq`, but still works when you have
  # non-consecutive matching lines
  parallel -a "$f" -k resolve_deps | awk '!seen[$0]++'
}

# Fetches the script for a module from S3 and prints it to STDOUT, filtering out
# any shebang lines.
function script_for_module() {
  local module="$1"

  # Download script from S3 into a temp file.
  local s3_file="s3://$ZERKENV_BUCKET/$module.sh"
  local file=$(_mktemp)
  aws s3 cp "$s3_file" "$file" >&2

  # Discard shebang lines and append to script.
  grep -vhe '^#!' "$file"
}
export -f script_for_module

function build_script() {
  errcho "Building script..."
  parallel -a - -k script_for_module
}

# Given a comma-separated string representing a list of modules to source,
# builds a script that is the concatenation of each of the module scripts,
# including their dependency modules, and sources the script.
function source_modules() {
  local modules="$1"
  local all_modules=$(resolve_all_deps "$modules")
  errcho

  local script=$(_mktemp)
  (echo "#!/bin/sh"; echo -e "$all_modules" | build_script) > "$script"
  errcho

  if [[ "$skip_confirmation" != yes ]]; then
    errcho "-----"
    errcat "$script"
    errcho "-----"
    errcho
    errcho "-----"
    errcho "Press ENTER to run this script, or ^C to cancel."
    errcho "-----"
    read
  fi

  # add the names of the modules we're sourcing to ZERKENV_MODULES
  add_to_loaded_modules "$all_modules"

  errcho "Sourcing script..."
  . "$script"

  errcho "Done."
}

# Given a filename like `foo.sh` or `foo.deps`, downloads it from S3 and prints
# its contents to STDOUT.
function download_file() {
  local filename="$1"
  local s3_file="s3://$ZERKENV_BUCKET/$filename"
  local file=$(_mktemp)

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
  local s3_file="s3://$ZERKENV_BUCKET/$filename"

  aws s3 cp "$file" "$s3_file" >&2

  return 0
}

function list_modules() {
  aws s3 ls "s3://$ZERKENV_BUCKET" \
    | sed 's/ \+/\t/g' \
    | cut -f4 \
    | sed 's/\(.*\).\(sh\|deps\)/\1/g' \
    | uniq
}

################################################################################

usage=$(cat <<EOF
usage: zerkenv [options/arguments ...]

options:
  -d, --download MODULE       download a module from S3
  -h, --help                  show this help message and exit
  -l, --list                  list available modules in S3 bucket
  -s, --source M1,M2,M3,...   source modules
  -u, --upload MODULE         upload a module to S3
  -y, --yes                   skip confirmation (used with -s/--source)

examples:
  List modules available:
    zerkenv -l

  Source modules:
    zerkenv -s foo,bar,baz

  Download a module
    zerkenv -d mod1 > mod1.sh

  Upload a module
    cat mod1.sh | zerkenv -u mod1.sh
EOF
)

# Have to null these out up here because we are sourcing the file and don't want
# them to still have the value from the last time the file was sourced.
skip_confirmation=""
list_modules=""
source_modules=""
download_file=""
upload_file=""

while [[ "$1" != "" ]]; do
   case "$1" in
       "--help" | "-h")
         echo "$usage"
         return 0
         ;;
       "--yes" | "-y")
         skip_confirmation=yes
         ;;
       "--list" | "-l")
         list_modules=yes
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
elif [[ "$list_modules" == "yes" ]]; then
  list_modules
else
  echo "$usage"
fi

