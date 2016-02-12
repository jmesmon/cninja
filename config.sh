# ex: sts=8 sw=8 ts=8 noet
set -eu -o pipefail

: ${CROSS_COMPILER:=}
: ${HOST_CC:=cc}
: ${CC:=${CROSS_COMPILER}cc}
: ${OBJCOPY:=${CROSS_COMPILER}objcopy}

: ${PKGCONFIG:=pkg-config}
: ${WARN_FLAGS_C:="-Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition -Wmissing-declarations -Wbad-function-cast"}
: ${WARN_FLAGS:="-Wall -Wundef -Wshadow -Wcast-align -Wwrite-strings -Wextra -Werror=attributes -Wno-missing-field-initializers ${WARN_FLAGS_C}"}
: ${GIT_VER:=$(${GIT:-git} describe --dirty=+ --always --abbrev=0 2>/dev/null || echo "+")}

if [ -n "${PKGCONFIG_LIBS:=}" ]; then
	PKGCONFIG_CFLAGS="$(${PKGCONFIG} --cflags ${PKGCONFIG_LIBS})"
	PKGCONFIG_LDFLAGS="$(${PKGCONFIG} --libs ${PKGCONFIG_LIBS})"
else
	PKGCONFIG_CFLAGS=""
	PKGCONFIG_LDFLAGS=""
fi

LIB_CFLAGS="${LIB_CFLAGS:-} ${PKGCONFIG_CFLAGS} "
LIB_LDFLAGS="${LIB_LDFLAGS:-} ${PKGCONFIG_LDFLAGS}"

ALL_CFLAGS="${WARN_FLAGS} -std=c11 -D_GNU_SOURCE"

if_runs () {
	local y=$1
	local n=$2
	shift 2
	"$@" >/dev/null 2>&1 && printf "%s" "$y" || printf "%s" "$n"
}

# Given a series of flags for CC, echo (space seperated) the ones that the
# compiler is happy with.
# XXX: Note that this does mean flags with spaces in them won't work.
cflag_x () {
	local cc=$(eval printf "%s" "\${$1CC}")
	local cflags=$(eval printf "%s" "\${$1CFLAGS:-}")
	shift
	for i in "$@"; do
		if_runs "$i " "" $cc $cflags -c -x c "$i" /dev/null -o /dev/null
	done
}

die () {
	>&2 echo "Error: $*"
	exit 1
}

: ${EXTRA_FLAGS=}
: ${SANITIZE_FLAGS="-fsanitize=address"}
: ${DEBUG_FLAGS="-ggdb3"}
: ${LTO_FLAGS="-flto"}
COMMON_FLAGS="$(cflag_x "" ${SANITIZE_FLAGS} ${LTO_FLAGS} -fsanitize=undefined -fvar-tracking-assignments)"
: ${CFLAGS="${ALL_CFLAGS} ${COMMON_FLAGS} -Os ${DEBUG_FLAGS} ${EXTRA_FLAGS}"}

# Without LIB_CFLAGS
: ${HOST_CFLAGS:=${CFLAGS:-}}

CFLAGS="-DCFG_GIT_VERSION=${GIT_VER} -I. ${LIB_CFLAGS} ${CFLAGS:-}"

: ${LDFLAGS:="${COMMON_FLAGS}"}
LDFLAGS="${LIB_LDFLAGS} ${LDFLAGS} ${DEBUG_FLAGS}"

CONFIG_H_GEN=./config_h_gen

CONFIGS=""

# Check if compiler likes -MMD -MF
if $CC $CFLAGS -MMD -MF /dev/null -c -x c /dev/null -o /dev/null >/dev/null 2>&1; then
	DEP_LINE="  depfile = \$out.d"
	DEP_FLAGS="-MMD -MF \$out.d"
else
	DEP_LINE=""
	DEP_FLAGS=""
fi

exec >build.ninja
echo "# generated by config.sh"

cat <<EOF
cc = $CC
objcopy = $OBJCOPY
cflags = $CFLAGS
ldflags = $LDFLAGS

rule cc
  command = \$cc \$cflags $DEP_FLAGS  -c \$in -o \$out
$DEP_LINE

rule ccld
  command = \$cc \$ldflags -o \$out \$in

rule config_h_frag
  command = ${CONFIG_H_GEN} \$in \$cc \$cflags \$ldflags > \$out

rule combine
  command = cat \$in > \$out

rule ninja_gen
  command = $0
  generator = yes
EOF

CONFIGURE_DEPS="$0"

to_out () {
  for i in "$@"; do
    printf "%s " ".build-$out/$i"
  done
}

to_obj () {
  for i in "$@"; do
    printf "%s " ".build-$out/$i.o"
  done
}

_ev () {
	eval echo "\${$1}"
}

config () {
	local configs=""
	for i in config_h/*.c; do
		local name=".config.h-$i-frag"
		echo "build $name : config_h_frag $i | ./if_compiles ${CONFIG_H_GEN}"
		configs="$configs $name"
	done

	echo "build config.h : combine config_h/prefix.h $configs config_h/suffix.h"
}

if [ -e "config_h" ]; then
	CONFIG_H=true
else
	CONFIG_H=false
fi

# If any files in config_h change, we need to re-generate build.ninja
if $CONFIG_H; then
	CONFIGURE_DEPS="$CONFIGURE_DEPS config_h/ ${CONFIG_H_GEN}"
fi

e_if() {
	v=$1
	shift
	if $v; then
		echo "$@"
	fi
}

bin () {
	if [ "$#" -lt 2 ]; then
		die "'bin $1' has to have some source"
	fi
	out="$1"
	shift
	out_var="${out/./_}"

	for s in "$@"; do
		echo "build $(to_obj "$s"): cc $s | $(e_if $CONFIG_H config.h)"
		echo "  cflags = \$cflags -I.build-$out"
	done

	cat <<EOF
build $out : ccld $(to_obj "$@")
EOF
	BINS="$BINS $out"
}
BINS=""

end_of_ninja () {
	echo build build.ninja : ninja_gen $CONFIGURE_DEPS
	echo default ${BINS}
}

trap end_of_ninja EXIT
