#!/bin/sh
# fus-update-gen-certs.sh — generate self-signed DEV signing material for
# RAUC bundles into <CERT_DIR>/<VARIANT>/.
#
# build-host helper, run outside bitbake; the recipes only read the
# resulting files. idempotent (use --force to rotate); refuses to generate
# "prod" material — production keys are provided out of band.
#
# layout produced (matches the recipe expectations):
#   <dir>/<variant>/ca.cert.pem     CA certificate -> device keyring
#   <dir>/<variant>/ca.key.pem      CA private key (not shipped)
#   <dir>/<variant>/sign.cert.pem   bundle signing certificate
#   <dir>/<variant>/sign.key.pem    bundle signing key
set -eu

CERT_DIR="${FUS_UPDATE_CERT_DIR:-}"
VARIANT="${FUS_UPDATE_CERT_VARIANT:-dev}"
OPENSSL="${OPENSSL_BIN:-openssl}"
FORCE=0
ORG="${FUS_UPDATE_CERT_ORG:-F&S Embedded}"
DAYS="${FUS_UPDATE_CERT_DAYS:-3650}"

usage() {
	echo "Usage: FUS_UPDATE_CERT_DIR=<dir> $0 [--variant dev] [--dir <dir>] [--force]" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--variant) VARIANT="$2"; shift 2 ;;
	--variant=*) VARIANT="${1#*=}"; shift ;;
	--dir) CERT_DIR="$2"; shift 2 ;;
	--dir=*) CERT_DIR="${1#*=}"; shift ;;
	--force) FORCE=1; shift ;;
	-h|--help) usage ;;
	*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$CERT_DIR" ] || { echo "ERROR: FUS_UPDATE_CERT_DIR / --dir not set" >&2; usage; }

if [ "$VARIANT" = "prod" ]; then
	echo "ERROR: refusing to generate 'prod' signing material." >&2
	echo "       Provide production keys out of band and point" >&2
	echo "       FUS_UPDATE_CERT_DIR at them." >&2
	exit 1
fi

OUT="$CERT_DIR/$VARIANT"
KEYRING="$OUT/ca.cert.pem"

if [ -f "$KEYRING" ] && [ "$FORCE" -ne 1 ]; then
	echo "[certs] keyring already present: $KEYRING (use --force to rotate)"
	exit 0
fi

mkdir -p "$OUT"
umask 077

echo "[certs] generating '$VARIANT' RAUC signing material in $OUT"

# self-signed CA -> shipped to the device as the RAUC keyring.
"$OPENSSL" req -x509 -newkey rsa:4096 -nodes \
	-keyout "$OUT/ca.key.pem" -out "$OUT/ca.cert.pem" -days "$DAYS" \
	-subj "/O=$ORG/CN=$ORG $VARIANT RAUC CA" \
	-addext "basicConstraints=critical,CA:TRUE" \
	-addext "keyUsage=critical,keyCertSign,cRLSign"

# leaf bundle-signing certificate, signed by the CA.
"$OPENSSL" req -newkey rsa:4096 -nodes \
	-keyout "$OUT/sign.key.pem" -out "$OUT/sign.csr.pem" \
	-subj "/O=$ORG/CN=$ORG $VARIANT bundle signer"
"$OPENSSL" x509 -req -in "$OUT/sign.csr.pem" \
	-CA "$OUT/ca.cert.pem" -CAkey "$OUT/ca.key.pem" -CAcreateserial \
	-out "$OUT/sign.cert.pem" -days "$DAYS" \
	-extfile /dev/stdin <<-EOF
		basicConstraints=critical,CA:FALSE
		keyUsage=critical,digitalSignature
		extendedKeyUsage=codeSigning
	EOF

rm -f "$OUT/sign.csr.pem" "$OUT"/*.srl
chmod 0600 "$OUT/ca.key.pem" "$OUT/sign.key.pem"
chmod 0644 "$OUT/ca.cert.pem" "$OUT/sign.cert.pem"

echo "[certs] done:"
ls -l "$OUT"
