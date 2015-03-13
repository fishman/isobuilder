#!/bin/sh

# Change this line to the URI path of the xcode DMG file.
XCODE_PATH="$1"


# rm login.html
# rm cookies
if [ ! "$ADC_USER" ]; then
    echo "Enter your Apple Dev Center username."
    read -p "> " ADC_USER

    shift
fi
if [ ! "$ADC_PASSWORD" ]; then
    echo "Enter your Apple Dev Center password."
    read -p "> " ADC_PASSWORD
    shift
fi

COOKIE="$(mktemp /tmp/tmp.XXXXXXXXXX)"

usage() {
    echo "Usage: $0 <ADC username> <ADC password>" 1>&2
    exit $1
}

if [ ! "$ADC_USER" -o ! "$ADC_PASSWORD" -o "$1" ]; then
    echo "Missing or extra parameter." 1>&2
    usage 1
fi

# Get login URL with jsessionid.
[[ $(curl -s -L -c ${COOKIE} "https://developer.apple.com/downloads/index.action") =~ form[^\>]+action=\"([^\"]+)\" ]] && LOGIN_URL="https://idmsa.apple.com/IDMSWebAuth/${BASH_REMATCH[1]}"

# Log in using $ADC_USER and $ADC_PASSWORD.
curl -s -L -b $COOKIE -c $COOKIE \
    -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_3) AppleWebKit/537.75.14 (KHTML, like Gecko) Version/7.0.3 Safari/7046A194A" \
    -d "appleId=${ADC_USER}&accountPassword=${ADC_PASSWORD}" $LOGIN_URL -o /dev/null
if ! grep -q myacinfo $COOKIE 2>/dev/null; then
    echo "Login failed." 1>&2
    exit 2
fi

curl \
    -L --cookie-jar ${COOKIE} --cookie ${COOKIE} \
    -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_3) AppleWebKit/537.75.14 (KHTML, like Gecko) Version/7.0.3 Safari/7046A194A" \
    -O https://developer.apple.com/devcenter/download.action?path=${XCODE_PATH}

rm ${COOKIE}
