#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
sound_root="$repo_root/Resources/NumaSounds"
generator="$repo_root/Tools/NumaSounds/generate.py"

fail() {
    print -u2 "numa sound contract: $*"
    exit 1
}

[[ -x "$generator" ]] || fail "missing executable generator: $generator"
[[ -f "$sound_root/LICENSE.md" ]] || fail "missing sound provenance/license"

themes=(crystal pulse organic digital)
expected=()
for theme in $themes; do
    expected+=("$sound_root/$theme-activation.aiff")
    expected+=("$sound_root/$theme-finish.aiff")
done

for asset in $expected; do
    [[ -s "$asset" ]] || fail "missing or empty asset: ${asset:t}"

    codec=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$asset")
    channels=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=channels -of default=nw=1:nk=1 "$asset")
    sample_rate=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=sample_rate -of default=nw=1:nk=1 "$asset")

    [[ "$codec" == "pcm_s16be" ]] || fail "${asset:t}: expected pcm_s16be, got $codec"
    [[ "$channels" == "1" ]] || fail "${asset:t}: expected mono, got $channels channels"
    [[ "$sample_rate" == "16000" ]] || fail "${asset:t}: expected 16 kHz, got $sample_rate"
done

for theme in $themes; do
    activation="$sound_root/$theme-activation.aiff"
    finish="$sound_root/$theme-finish.aiff"
    activation_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=nw=1:nk=1 "$activation")
    finish_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=nw=1:nk=1 "$finish")

    awk -v d="$activation_duration" 'BEGIN { exit !(d > 0.05 && d <= 0.250) }' \
        || fail "$theme activation duration $activation_duration is outside (0.05, 0.250]"
    awk -v d="$finish_duration" 'BEGIN { exit !(d > 0.10 && d <= 0.500) }' \
        || fail "$theme finish duration $finish_duration is outside (0.10, 0.500]"

    [[ "$(shasum -a 256 "$activation" | awk '{print $1}')" != \
       "$(shasum -a 256 "$finish" | awk '{print $1}')" ]] \
        || fail "$theme activation and finish assets are identical"
done

unique_hashes=$(shasum -a 256 $expected | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
[[ "$unique_hashes" == "8" ]] || fail "expected eight distinct assets, got $unique_hashes"

before=$(mktemp)
after=$(mktemp)
trap 'rm -f "$before" "$after"' EXIT
shasum -a 256 $expected > "$before"
"$generator"
shasum -a 256 $expected > "$after"
cmp -s "$before" "$after" || fail "generator is not byte-for-byte deterministic"

echo "numa sound contract: PASS — 8 deterministic original AIFF assets"
