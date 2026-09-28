#!/bin/sh
# Resolve the release tag: the most recently *created* tag matching
# TAG_PATTERN (shell glob; `*` also matches `/`). Chronology, not version parsing:
# annotated tags sort by tagger date, lightweight tags by commit date.
# Equal timestamps tie-break on refname for determinism.
#
# This repo follows DEP-14:
#   debian/<version>    Debian packaging release  <- default release source
#   upstream/<version>  upstream source import (no debian/, no Makefile)
#   debian/<codename>   archival snapshot of a Debian suite (no version)
# Hence the default pattern `debian/[0-9]*` (versions always start with a
# digit, codenames never do).
#
# env:  TAG_PATTERN   (default 'debian/[0-9]*')
#       TAG_OVERRIDE  explicit tag; must exist
# out:  tag, safe (filesystem/asset-safe form), sha, version  -> $GITHUB_OUTPUT

set -eu

pattern=${TAG_PATTERN:-'debian/[0-9]*'}
override=${TAG_OVERRIDE:-}

if [ -n "$override" ]; then
    git rev-parse -q --verify "refs/tags/$override" >/dev/null \
        || { echo "::error::tag '$override' does not exist" >&2; exit 1; }
    tag=$override
else
    # Filter with `case` rather than a for-each-ref pattern: git's ref globs
    # stop `*` at '/', which breaks prefixes that themselves contain slashes.
    tag=
    for t in $(git for-each-ref --sort=refname --sort=-creatordate \
                   --format='%(refname:strip=2)' refs/tags/); do
        # shellcheck disable=SC2254
        case $t in $pattern) tag=$t; break ;; esac
    done
    [ -n "$tag" ] || { echo "::error::no tag matches '$pattern' (fetch-depth: 0 + tags needed)" >&2; exit 1; }
fi

# Peel annotated tags to the commit.
sha=$(git rev-parse "refs/tags/$tag^{commit}")
# Last path component carries the version; prefixes may nest (a/b/1.0).
version=${tag##*/}
# Asset/artifact names cannot contain '/', and some tools choke on other
# shell/URL-significant characters. '+' and '~' are legal but normalized too.
safe=$(printf '%s' "$tag" | tr '/+~: ' '-----')

echo "Resolved tag: $tag -> $sha (version $version, safe name $safe)"
{
    echo "tag=$tag"
    echo "safe=$safe"
    echo "sha=$sha"
    echo "version=$version"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
