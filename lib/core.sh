#!/usr/bin/env bash
core_binary_version() {
    local actual
    actual=$(timeout 15 "$1" version | awk '/^sing-box version /{print $3}')
    [[ $actual =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '只接受具有正式版本号的 sing-box 稳定内核'
    printf '%s\n' "$actual"
}
core_api_download() {
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 45 --retry 2 --retry-all-errors --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' "$1" --output "$2"
}
core_release_fetch() {
    local requested=${1:-latest} directory=$2 endpoint version arch asset
    if [[ $requested == latest ]]; then endpoint=latest
    else
        requested=${requested#v}
        [[ $requested =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '内核版本必须是正式版本号或 latest'
        endpoint="tags/v$requested"
    fi
    core_api_download "https://api.github.com/repos/SagerNet/sing-box/releases/$endpoint" "$directory/release.json" || die '无法获取官方内核发布信息；现有内核未变更'
    jq -e '.draft==false and .prerelease==false and (.tag_name|test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.assets|type)=="array"' "$directory/release.json" >/dev/null || die '官方发布不是有效的稳定版本'
    version=$(jq -r '.tag_name|ltrimstr("v")' "$directory/release.json")
    [[ $requested == latest || $version == "$requested" ]] || die '发布版本与请求不一致'
    case $(uname -m) in aarch64|arm64) arch=arm64;; x86_64|amd64) arch=amd64;; *) die '仅支持 amd64/arm64';; esac
    asset="sing-box-$version-linux-$arch.tar.gz"
    jq -e --arg asset "$asset" --arg version "$version" '
      [.assets[]|select(.name==$asset)] |
      if length==1 then .[0] else error("asset missing or ambiguous") end |
      select((.digest//""|test("^sha256:[a-f0-9]{64}$")) and
        .browser_download_url==("https://github.com/SagerNet/sing-box/releases/download/v"+$version+"/"+$asset)) |
      {version:$version,asset:.name,url:.browser_download_url,archive_sha256:(.digest|ltrimstr("sha256:"))}' \
        "$directory/release.json" > "$directory/asset.json" || die '官方发布缺少唯一的目标架构制品或可信 SHA-256 摘要'
}
core_extract() {
    local version=$1 asset=$2 url=$3 digest=$4 destination=$5 cached actual
    mkdir -p "$SB_ROOT/cache" "$(dirname "$destination")"
    cached="$SB_ROOT/cache/$asset"
    if [[ ! -f $cached || $(hash_file "$cached") != "$digest" ]]; then download "$url" "$cached" "$digest"; fi
    # Read just the expected binary; do not extract arbitrary archive members.
    tar -xOzf "$cached" "${asset%.tar.gz}/sing-box" > "$destination"
    chmod 755 "$destination"
    actual=$(core_binary_version "$destination")
    [[ $actual == "$version" ]] || die '制品内核版本与官方发布不一致'
}
core_prepare() {
    local directory=$1
    core_extract "$(jq -r .version "$directory/asset.json")" "$(jq -r .asset "$directory/asset.json")" \
        "$(jq -r .url "$directory/asset.json")" "$(jq -r .archive_sha256 "$directory/asset.json")" "$directory/candidate"
}
core_install_metadata() {
    local asset=$1 binary=$2
    jq --arg hash "$(hash_file "$binary")" '.+{binary_sha256:$hash,validated:true,installed_at:(now|todateiso8601)}' "$asset" > "$SB_ROOT/.core-installed.tmp"
    mv -f "$SB_ROOT/.core-installed.tmp" "$SB_ROOT/core-installed.json"
}
download_core() (
    set -Eeuo pipefail
    local version=${1:-} destination=${2:-$SB_CORE} baseline arch asset url digest directory
    baseline=$(jq -r .core_version "$SB_HOME/dependencies.lock.json")
    version=${version:-$baseline}; version=${version#v}
    mkdir -p "$SB_ROOT/cache" "$(dirname "$destination")"
    directory=$(mktemp -d "$SB_ROOT/cache/download-core.XXXXXXXX")
    trap 'rm -rf -- "$directory"' EXIT
    if [[ $version == "$baseline" ]]; then
        case $(uname -m) in aarch64|arm64) arch=arm64;; x86_64|amd64) arch=amd64;; *) die '仅支持 amd64/arm64';; esac
        asset="sing-box-$version-linux-$arch.tar.gz"
        url=$(jq -r --arg a "$asset" '.assets[$a].url' "$SB_HOME/dependencies.lock.json")
        digest=$(jq -r --arg a "$asset" '.assets[$a].sha256' "$SB_HOME/dependencies.lock.json")
        [[ $url == "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" && $digest =~ ^[a-f0-9]{64}$ ]] || die '缺少内核制品及校验值'
        core_extract "$version" "$asset" "$url" "$digest" "$directory/candidate"
        jq -n --arg version "$version" --arg asset "$asset" --arg url "$url" --arg hash "$digest" \
            '{version:$version,asset:$asset,url:$url,archive_sha256:$hash}' > "$directory/asset.json"
    else core_release_fetch "$version" "$directory"; core_prepare "$directory"; fi
    install -m755 "$directory/candidate" "$destination"
    if [[ $destination == "$SB_CORE" ]]; then core_install_metadata "$directory/asset.json" "$destination"; fi
)
core_option_snapshot() {
    local version=$1 directory=$2 member relative prefix="sing-box-$1/" count=0
    mkdir -p "$directory"
    core_api_download "https://codeload.github.com/SagerNet/sing-box/tar.gz/refs/tags/v$version" "$directory/source.tar.gz" || return 1
    gzip -dc "$directory/source.tar.gz" > "$directory/source.tar" || return 1
    tar -tf "$directory/source.tar" > "$directory/all-members" || return 1
    : > "$directory/members"
    while IFS= read -r member; do
        relative=${member#"$prefix"}
        if [[ $member == "$prefix"* && $relative =~ ^option/([a-zA-Z0-9_]+/)*[a-zA-Z0-9_]+\.go$ ]]; then
            printf '%s\n' "$member" >> "$directory/members"; (( count+=1 ))
        fi
    done < "$directory/all-members"
    (( count>0 )) || return 1
    tar -tvf "$directory/source.tar" -T "$directory/members" > "$directory/types" || return 1
    while IFS= read -r member; do [[ ${member:0:1} == - ]] || return 1; done < "$directory/types"
    : > "$directory/fields.ndjson"
    while IFS= read -r member; do
        tar -xOf "$directory/source.tar" "$member" |
            jq -R --arg file "${member#"$prefix"}" 'try capture("json:\"(?<field>[A-Za-z_][A-Za-z0-9_-]*)")|{file:$file,field:.field}' >> "$directory/fields.ndjson" || return 1
    done < "$directory/members"
    jq -s 'unique' "$directory/fields.ndjson" > "$directory/fields.json" || return 1
    rm -f "$directory/source.tar" "$directory/source.tar.gz"
}
core_fields_from_source() {
    local old=$1 new=$2 directory=$3 source=$4
    core_option_snapshot "$old" "$directory/options-old" || return 1
    core_option_snapshot "$new" "$directory/options-new" || return 1
    jq -n --slurpfile old "$directory/options-old/fields.json" --slurpfile new "$directory/options-new/fields.json" --arg source "$source" \
        '{status:"complete",method:"official-source-option-tags",source:$source,added:($new[0]-$old[0]),removed:($old[0]-$new[0])}' > "$directory/fields.new.json" || return 1
    mv -f "$directory/fields.new.json" "$directory/fields.json"
}
core_field_report() {
    local old=$1 new=$2 directory=$3 source="https://github.com/SagerNet/sing-box/compare/v$1...v$2"
    jq -r '.body//""' "$directory/release.json" > "$directory/release-notes.txt"
    if [[ $old == "$new" ]]; then
        jq -n --arg source "$source" '{status:"unchanged",source:$source,added:[],removed:[]}' > "$directory/fields.json"
    elif core_api_download "https://api.github.com/repos/SagerNet/sing-box/compare/v$old...v$new" "$directory/compare.json" &&
         jq -e '.files|type=="array"' "$directory/compare.json" >/dev/null; then
        jq -f "$SB_HOME/jq/core-fields.jq" --arg source "$source" "$directory/compare.json" > "$directory/fields.json"
    else jq -n --arg source "$source" '{status:"unavailable",source:$source,added:[],removed:[]}' > "$directory/fields.json"; fi
    if jq -e '.status|IN("partial","unavailable")' "$directory/fields.json" >/dev/null; then
        note '官方差异列表不完整，尝试比较两个版本的 option 源码字段……'
        if ! core_fields_from_source "$old" "$new" "$directory" "$source"; then note '源码字段补充检测未完成，将保留不完整检测提示'; fi
    fi
    core_show_report "$old" "$new" "$directory"
}
core_show_report() {
    local old=$1 new=$2 directory=$3 status
    note "当前服务端内核: $old；目标稳定内核: $new"
    note "官方发布: https://github.com/SagerNet/sing-box/releases/tag/v$new"
    status=$(jq -r .status "$directory/fields.json")
    if jq -e '(.added|length)>0 or (.removed|length)>0' "$directory/fields.json" >/dev/null; then
        note "发现配置字段变化：新增 $(jq '.added|length' "$directory/fields.json") 项，移除/迁移 $(jq '.removed|length' "$directory/fields.json") 项（每类显示前 20 项）："
        jq -r '(.added[:20][]|"  新增: \(.file) · \(.field)"),(.removed[:20][]|"  移除/迁移: \(.file) · \(.field)")' "$directory/fields.json" >&2
        note '新字段不会自动写入现有节点，需要管理脚本或菜单适配后按需启用；升级前会用新内核检查当前配置。'
    elif [[ $status == complete ]]; then note '在可获取的官方 option 字段差异中未发现新增或移除字段；其他行为变化仍请查看发行说明。'
    elif [[ $status == unchanged ]]; then note '当前已是目标版本。'
    fi
    if [[ $status == partial || $status == unavailable ]]; then
        note '字段差异未能完整获取，不能据此认为没有新字段。请查看官方发行说明和迁移文档。'
    fi
    if [[ -s $directory/release-notes.txt ]]; then
        note '官方发行说明（前 20 行）：'
        head -n 20 "$directory/release-notes.txt" >&2
    fi
    note '迁移文档: https://sing-box.sagernet.org/migration/'
    note "完整检查记录: $directory"
}
core_validate_candidate() {
    local directory=$1 state
    state=$(read_state)
    write_generation "$state" "$directory/rendered"
    if ! "$directory/candidate" check -c "$SB_ROOT/current/config.json" > "$directory/current-check.log" 2>&1; then
        cat "$directory/current-check.log" >&2
        die '新内核不接受现有运行配置；可能存在废弃字段或新增必填项。请先更新脚本或处理迁移，旧内核未变更'
    fi
    if ! "$directory/candidate" check -c "$directory/rendered/config.json" > "$directory/rendered-check.log" 2>&1; then
        cat "$directory/rendered-check.log" >&2
        die '当前脚本生成的配置不兼容新内核，请先 sb update sh；旧内核未变更'
    fi
    # Successful validation may still carry migration/deprecation warnings.
    if [[ -s $directory/current-check.log || -s $directory/rendered-check.log ]]; then
        note '新内核配置检查提示：'
        cat "$directory/current-check.log" "$directory/rendered-check.log" >&2
    fi
}
core_journal_phase() {
    jq --arg phase "$1" '.phase=$phase' "$SB_ROOT/core-update.json" > "$SB_ROOT/.core-update.tmp"
    mv -f "$SB_ROOT/.core-update.tmp" "$SB_ROOT/core-update.json"
}
recover_core_update() {
    [[ -f $SB_ROOT/core-update.json ]] || return 0
    local phase id
    phase=$(jq -r .phase "$SB_ROOT/core-update.json")
    id=$(jq -r .id "$SB_ROOT/core-update.json")
    [[ ${SB_CORE_UPDATE_ACTIVE:-} != "$id" ]] || return 0
    case $phase in switching|applying) core_restore_update;; esac
}
core_restore_update() {
    local backup old ca na path
    backup=$(jq -r .backup "$SB_ROOT/core-update.json")
    old=$(jq -r .old_generation "$SB_ROOT/core-update.json")
    path=$(jq -r .core_path "$SB_ROOT/core-update.json")
    [[ $backup == "$SB_ROOT/core-versions/"* && ${backup##*/} =~ ^[a-zA-Z0-9-]+$ && $old =~ ^generations/[a-zA-Z0-9-]+$ && $path == "$SB_CORE" ]] || { note '内核回滚记录路径无效'; return 1; }
    [[ $(hash_file "$backup/core") == "$(jq -r .old_binary_sha256 "$SB_ROOT/core-update.json")" ]] || { note '旧内核快照校验失败'; return 1; }
    ca=$(jq -r .core_active "$SB_ROOT/core-update.json"); na=$(jq -r .nginx_active "$SB_ROOT/core-update.json")
    service_action core stop || return 1
    install -m755 "$backup/core" "$SB_CORE.rollback" || return 1
    mv -f "$SB_CORE.rollback" "$SB_CORE" || return 1
    if [[ -f $backup/core-installed.json ]]; then
        cp "$backup/core-installed.json" "$SB_ROOT/.core-installed.tmp" || return 1
        mv -f "$SB_ROOT/.core-installed.tmp" "$SB_ROOT/core-installed.json" || return 1
    else rm -f "$SB_ROOT/core-installed.json" || return 1; fi
    journal_write applying "$old" "$(readlink "$SB_ROOT/current")" "$ca" "$na" || return 1
    rollback_transaction || return 1
    core_journal_phase rolled-back || return 1
    note '已恢复旧内核、原配置和升级前服务状态'
}
_core_update_apply() (
    set -Eeuo pipefail
    local directory=$1 expected_hash=$2 id backup ca=false na=false switched=false rc=0
    recover_transaction
    [[ $(hash_file "$SB_CORE") == "$expected_hash" ]] || die '检查期间内核已被其他操作变更，请重新执行更新'
    core_validate_candidate "$directory"
    service_active core && ca=true
    service_active nginx && na=true
    id=$(stamp); backup="$SB_ROOT/core-versions/$id"
    mkdir -p "$backup"
    cp -p "$SB_CORE" "$backup/core"
    [[ ! -f $SB_ROOT/core-installed.json ]] || cp "$SB_ROOT/core-installed.json" "$backup/core-installed.json"
    jq -n --arg id "$id" --arg backup "$backup" --arg old "$(readlink "$SB_ROOT/current")" \
        --arg path "$SB_CORE" --arg hash "$expected_hash" --argjson ca "$ca" --argjson na "$na" \
        '{id:$id,phase:"switching",backup:$backup,old_generation:$old,core_path:$path,old_binary_sha256:$hash,core_active:$ca,nginx_active:$na}' > "$SB_ROOT/.core-update.tmp"
    mv -f "$SB_ROOT/.core-update.tmp" "$SB_ROOT/core-update.json"
    local SB_CORE_UPDATE_ACTIVE=$id
    trap 'rc=$?; if (( rc != 0 )) && [[ $switched == true ]]; then trap - EXIT; core_restore_update || note "内核自动恢复失败，请检查 core-update.json"; fi; exit "$rc"' EXIT
    trap 'exit 130' INT TERM
    switched=true
    install -m755 "$directory/candidate" "$SB_CORE.new"
    mv -f "$SB_CORE.new" "$SB_CORE"
    core_install_metadata "$directory/asset.json" "$SB_CORE"
    core_journal_phase applying
    SB_FORCE_CORE=1 _apply_state "$(read_state)"
    core_journal_phase committed
    switched=false
    note "内核已更新至 $(core_binary_version "$SB_CORE")；原内核快照: $backup"
)
update_core() (
    set -Eeuo pipefail
    local requested=latest version_set=false check_only=false directory current target old_hash
    while (( $# )); do
        case $1 in
            --check) check_only=true; shift;;
            --*) die 'update core 仅接受 [版本|latest] [--check]';;
            *) [[ $version_set == false ]] || die '内核版本参数过多'; requested=$1; version_set=true; shift;;
        esac
    done
    current=$(core_binary_version "$SB_CORE"); old_hash=$(hash_file "$SB_CORE")
    mkdir -p "$SB_ROOT/reports"
    directory=$(mktemp -d "$SB_ROOT/reports/core-check.XXXXXXXX")
    trap 'rm -f -- "$directory/candidate"' EXIT
    core_release_fetch "$requested" "$directory"
    target=$(jq -r .version "$directory/asset.json")
    [[ $(printf '%s\n' "$current" "$target" | sort -V | head -n1) == "$current" ]] || die '不自动降级内核，请选择当前或更新的稳定版本'
    core_field_report "$current" "$target" "$directory"
    if [[ $target == "$current" ]]; then
        if [[ $current == "$(jq -r .core_version "$SB_HOME/dependencies.lock.json")" ]] ||
           { [[ -f $SB_ROOT/core-installed.json ]] && jq -e --arg version "$current" --arg hash "$old_hash" \
             '.validated==true and .version==$version and .binary_sha256==$hash' "$SB_ROOT/core-installed.json" >/dev/null; }; then return 0; fi
        note '当前版本缺少有效的管理器校验记录，将重新校验并安装官方制品。'
    fi
    core_prepare "$directory"
    if [[ $check_only == true ]]; then with_lock core_validate_candidate "$directory"; note '仅检查完成，内核和服务未变更'
    else with_lock _core_update_apply "$directory" "$old_hash"; fi
)
