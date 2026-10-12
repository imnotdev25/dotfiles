# LiteLLM model management: delete, metadata updates, and provider catalogs.

function __litellm_call --argument-names method url api_key path payload
    set -l separator '__LITELLM_HTTP_STATUS__'
    set -l args -sS -X "$method" -H "x-litellm-api-key: $api_key" -H 'Content-Type: application/json'
    test -n "$payload"; and set -a args -d "$payload"
    curl $args -w "$separator%{http_code}" "$url$path" | string collect
end

function __litellm_register_one --argument-names litellm_url api_key source_model public_name credential
    set -l payload (jq -cn \
      --arg source "$source_model" --arg public "$public_name" --arg credential "$credential" '
        {
          model_name: $public,
          litellm_params: {
            model: $source,
            custom_llm_provider: "openai",
            litellm_credential_name: $credential
          },
          model_info: {}
        }
      ')
    __litellm_call POST "$litellm_url" "$api_key" /model/new "$payload"
end

function __litellm_connection_error --argument-names litellm_url api_key
    if test -z "$litellm_url"
        echo 'Error: LiteLLM URL is required (set LITELLM_MG_URL or use -u)' >&2
        return 1
    end
    if test -z "$api_key"
        echo 'Error: API key is required (set LITELLM_MG_KEY or use -k)' >&2
        return 1
    end
end

function __litellm_normalize_public_name --argument-names name
    string lower -- "$name" \
      | string replace -r '^.*/' '' \
      | string replace -r '(:free|-free)$' '' \
      | string replace -r -- '-(20[0-9]{2}[-_.]?[0-9]{2}[-_.]?[0-9]{2}|[0-9]{4})$' '' \
      | string replace -ra '[^a-z0-9._-]+' '-' \
      | string replace -ra -- '-+' '-' \
      | string trim -c '-'
end

function __litellm_public_name --argument-names source explicit normalize
    set -l name "$explicit"
    test -z "$name"; and set name "$source"
    if test "$normalize" = true
        set name (__litellm_normalize_public_name "$name")
    end
    printf '%s\n' "$name"
end

function __litellm_filter_existing_entries --argument-names entries litellm_url api_key credential
    set -l existing (__litellm_existing_models "$litellm_url" "$api_key" "$credential"); or return 1
    jq -cn --argjson entries "$entries" --argjson existing "$existing" \
      '$entries | map(select(.source as $source | $existing | index($source) | not))'
end

function __litellm_verify_registered_model --argument-names litellm_url api_key public mode
    if test "$mode" = none
        return 0
    end
    if test "$mode" = connection
        set -l payload (jq -cn --arg model "$public" '{litellm_params: {model: $model}, mode: "chat"}')
        set -l response (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
          (__litellm_call POST "$litellm_url" "$api_key" /health/test_connection "$payload"))
        contains -- "$response[2]" 200 429
        return $status
    end
    set -l encoded (printf '%s' "$public" | jq -sRr @uri)
    set -l response (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
      (__litellm_call GET "$litellm_url" "$api_key" "/models/$encoded?healthy_only=true" ''))
    contains -- "$response[2]" 200 429
end

function __litellm_register_entries --argument-names entries litellm_url api_key credential verify
    test -z "$verify"; and set verify health
    set -l requested (printf '%s\n' "$entries" | jq 'length')
    set entries (__litellm_filter_existing_entries "$entries" "$litellm_url" "$api_key" "$credential"); or return 1
    set -l count (printf '%s\n' "$entries" | jq 'length')
    set -l skipped (math "$requested - $count")
    set -l succeeded 0
    set -l failed 0
    set -l unhealthy 0
    set -l index 1

    for entry in (printf '%s\n' "$entries" | jq -c '.[]')
        set -l source (printf '%s\n' "$entry" | jq -r '.source')
        set -l public (printf '%s\n' "$entry" | jq -r '.public')
        echo "[$index/$count] $source → $public"
        set -l result (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
          (__litellm_register_one "$litellm_url" "$api_key" "$source" "$public" "$credential"))
        if test "$result[2]" = 200
            echo '    ✓ Registered'
            set succeeded (math $succeeded + 1)
            if __litellm_verify_registered_model "$litellm_url" "$api_key" "$public" "$verify"
                test "$verify" != none; and echo '    ✓ Health check passed'
            else
                echo '    ✗ Health check failed'
                set unhealthy (math $unhealthy + 1)
            end
        else
            echo "    ✗ Failed (HTTP $result[2])"
            test -n "$result[1]"; and echo "    $result[1]"
            set failed (math $failed + 1)
        end
        set index (math $index + 1)
    end

    echo "Summary: $succeeded registered, $skipped already present, $failed failed, $unhealthy unhealthy"
    test "$failed" -eq 0; and test "$unhealthy" -eq 0
end

function __litellm_csv_entries --argument-names csv_path
    python3 -c '
import csv, json, sys
with open(sys.argv[1], newline="", encoding="utf-8-sig") as handle:
    for line, row in enumerate(csv.DictReader(handle), 2):
        source = next((str(row.get(k, "")).strip() for k in ("source_model", "provider_model", "model_name", "name", "model") if str(row.get(k, "")).strip()), "")
        public = next((str(row.get(k, "")).strip() for k in ("public_name", "alias", "public_model_name", "litellm_name") if str(row.get(k, "")).strip()), "")
        if not source:
            raise SystemExit(f"Error: missing model name in CSV row {line}")
        print(json.dumps({"source": source, "public": public}))
' "$csv_path"
end

function __litellm_choose_registration_mode
    command -q fzf; or begin
        echo 'Error: interactive registration requires fzf' >&2
        return 1
    end
    printf '%b\n' \
      'manual\t✎ Enter model name' \
      'openrouter\tOpenRouter free catalog' \
      'kilo\tKilo AI free catalog' \
      'zenmux\tZenMux free catalog' \
      'opencode\tOpenCode free catalog' \
      'tokenrouter\tToken Router free catalog' \
      'nous\tNous Research free catalog' \
      | fzf --delimiter='\t' --with-nth=2.. --accept-nth=1 --no-sort --prompt='Register › '
end

function __litellm_select_delete_entries --argument-names entries
    command -q fzf; or begin
        echo 'Error: interactive deletion requires fzf' >&2
        return 1
    end
    set -l choices
    set -l index 1
    for label in (printf '%s\n' "$entries" | jq -r '.[] | "\(.health // "unchecked")\t\(.model_name) [\(.credential)] ← \(.source)"')
        set -a choices "$index\t$label"
        set index (math $index + 1)
    end
    set -l selected (printf '%b\n' $choices | fzf --multi --no-sort --delimiter='\t' --with-nth=2.. --accept-nth=1 \
      --marker='✓' --pointer='›' --prompt='Delete › ' \
      --header='Tab: toggle  •  Ctrl-A: toggle all  •  Enter: confirm' --bind='ctrl-a:toggle-all')
    if test $status -ne 0; or test (count $selected) -eq 0
        echo '[]'
        return 0
    end
    printf '%s\n' $selected | jq -Rsc --argjson entries "$entries" '
      split("\n") | map(select(length > 0) | tonumber - 1) | unique | map($entries[.])
    '
end

function __litellm_add_health --argument-names entries litellm_url api_key
    set -l checked '[]'
    for entry in (printf '%s\n' "$entries" | jq -c '.[]')
        set -l public (printf '%s\n' "$entry" | jq -r '.model_name')
        set -l encoded (printf '%s' "$public" | jq -sRr @uri)
        set -l response (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
          (__litellm_call GET "$litellm_url" "$api_key" "/models/$encoded?healthy_only=true" ''))
        set -l health "HTTP $response[2]"
        test "$response[2]" = 200; and set health healthy
        test "$response[2]" = 404; and set health '404 unavailable'
        test "$response[2]" = 429; and set health '429 available (rate limited)'
        set checked (jq -cn --argjson rows "$checked" --argjson row "$entry" --arg health "$health" \
          '$rows + [$row + {health: $health}]')
    end
    echo "$checked"
end

function litellm_register
    set -l source
    set -l explicit_public
    set -l credential 'Azure Foundry'
    set -l credential_explicit false
    set -l normalize true
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l verify health

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case -n --name --source-model --provider-model
                set index (math $index + 1); set source $argv[$index]
            case -p --public-name --alias
                set index (math $index + 1); set explicit_public $argv[$index]
            case -c --credential --provider --credential-name
                set index (math $index + 1); set credential $argv[$index]; set credential_explicit true
            case --no-normalize
                set normalize false
            case --test-connection
                set verify connection
            case --no-health-check
                set verify none
            case -u --url
                set index (math $index + 1); set litellm_url $argv[$index]
            case -k --api-key
                set index (math $index + 1); set api_key $argv[$index]
            case -h --help
                echo 'Usage: litellm_register [MODEL] [OPTIONS]'
                echo '  With no MODEL, choose manual entry or a provider catalog interactively'
                echo '  -p, --public-name NAME  Explicit public alias'
                echo '  -c, --credential NAME   LiteLLM credential (default: Azure Foundry)'
                echo '  --no-normalize          Preserve the public alias exactly'
                echo '  --test-connection       Run LiteLLM connection test after registration'
                echo '  --no-health-check       Skip post-registration verification'
                echo '  -u/--url, -k/--api-key  Override LITELLM_MG_URL/LITELLM_MG_KEY'
                return 0
            case '*'
                if test -z "$source"
                    set source $argv[$index]
                else
                    echo "Error: unexpected argument '$argv[$index]'" >&2
                    return 1
                end
        end
        set index (math $index + 1)
    end

    if test -z "$source"
        if not status is-interactive; or not test -t 0
            echo 'Error: model name is required outside an interactive shell' >&2
            return 1
        end
        set -l mode (__litellm_choose_registration_mode); or return 1
        test -z "$mode"; and return 0
        if test "$mode" = manual
            read -l -P 'Provider model name: ' source
            test -z "$source"; and return 0
            read -l -P 'Public alias (Enter to normalize automatically): ' explicit_public
        else
            set -l config (__litellm_catalog_config "$mode"); or return 1
            if test "$credential_explicit" != true
                set credential $config[2]
            end
            set -l catalog_entries (__litellm_fetch_catalog_models "$mode" "$TOKENROUTER_API_KEY"); or return 1
            set -l entries '[]'
            for entry in (printf '%s\n' "$catalog_entries" | jq -c '.[]')
                set -l catalog_source (printf '%s\n' "$entry" | jq -r '.source')
                set -l suggested (printf '%s\n' "$entry" | jq -r '.public')
                set -l public (__litellm_public_name "$catalog_source" "$suggested" "$normalize")
                set entries (jq -cn --argjson rows "$entries" --arg source "$catalog_source" --arg public "$public" \
                  '$rows + [{source: $source, public: $public}]')
            end
            set entries (__litellm_select_models "$entries"); or return 1
            test (printf '%s\n' "$entries" | jq 'length') -eq 0; and return 0
            __litellm_connection_error "$litellm_url" "$api_key"; or return 1
            __litellm_register_entries "$entries" "$litellm_url" "$api_key" "$credential" "$verify"
            return $status
        end
    end
    __litellm_connection_error "$litellm_url" "$api_key"; or return 1
    set -l public (__litellm_public_name "$source" "$explicit_public" "$normalize")
    if test -z "$public"
        echo 'Error: normalized public name is empty' >&2
        return 1
    end
    set -l entries (jq -cn --arg source "$source" --arg public "$public" '[{source: $source, public: $public}]')
    __litellm_register_entries "$entries" "$litellm_url" "$api_key" "$credential" "$verify"
end

function litellm_register_bulk
    set -l sources
    set -l public_names
    set -l credential 'Azure Foundry'
    set -l normalize true
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l csv_path
    set -l verify health

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case -n --name --source-model --provider-model
                set index (math $index + 1); set -a sources $argv[$index]
            case -p --public-name --alias
                set index (math $index + 1); set -a public_names $argv[$index]
            case -c --credential --provider --credential-name
                set index (math $index + 1); set credential $argv[$index]
            case --no-normalize
                set normalize false
            case --test-connection
                set verify connection
            case --no-health-check
                set verify none
            case --csv
                set index (math $index + 1); set csv_path $argv[$index]
            case -u --url
                set index (math $index + 1); set litellm_url $argv[$index]
            case -k --api-key
                set index (math $index + 1); set api_key $argv[$index]
            case -h --help
                echo 'Usage: litellm_register_bulk MODEL... [OPTIONS]'
                echo '  -n MODEL can be repeated; -p ALIAS matches by position'
                echo '  --no-normalize preserves aliases exactly'
                echo '  --test-connection runs LiteLLM connection tests after registration'
                echo '  --no-health-check skips post-registration verification'
                echo '  --csv PATH loads source_model/model_name and public_name/alias columns'
                echo '  Connection defaults: LITELLM_MG_URL and LITELLM_MG_KEY'
                return 0
            case '*'
                set -a sources $argv[$index]
        end
        set index (math $index + 1)
    end

    __litellm_connection_error "$litellm_url" "$api_key"; or return 1
    if test (count $public_names) -gt (count $sources)
        echo 'Error: more aliases than source models' >&2
        return 1
    end

    set -l entries '[]'
    set index 1
    for source in $sources
        set -l public (__litellm_public_name "$source" "$public_names[$index]" "$normalize")
        set entries (jq -cn --argjson entries "$entries" --arg source "$source" --arg public "$public" \
          '$entries + [{source: $source, public: $public}]')
        set index (math $index + 1)
    end
    if test -n "$csv_path"
        set -l csv_entries (__litellm_csv_entries "$csv_path"); or return 1
        for entry in $csv_entries
            set -l source (printf '%s\n' "$entry" | jq -r '.source')
            set -l explicit (printf '%s\n' "$entry" | jq -r '.public')
            set -l public (__litellm_public_name "$source" "$explicit" "$normalize")
            set entries (jq -cn --argjson entries "$entries" --arg source "$source" --arg public "$public" \
              '$entries + [{source: $source, public: $public}]')
        end
    end

    if test (printf '%s\n' "$entries" | jq 'length') -eq 0
        echo 'Error: at least one model or --csv file is required' >&2
        return 1
    end
    __litellm_register_entries "$entries" "$litellm_url" "$api_key" "$credential" "$verify"
end

function litellm_delete
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l credential
    set -l model_name
    set -l prefix
    set -l use_regex false
    set -l force false
    set -l health_check false
    set -l unavailable_only false

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case -p --provider --credential
                set index (math $index + 1); set credential $argv[$index]
            case -m --model-name
                set index (math $index + 1); set model_name $argv[$index]
            case --prefix
                set index (math $index + 1); set prefix $argv[$index]
            case -r --regex
                set use_regex true
            case -f --force
                set force true
            case --health-check
                set health_check true
            case --unavailable --404
                set health_check true; set unavailable_only true
            case -u --url
                set index (math $index + 1); set litellm_url $argv[$index]
            case -k --api-key
                set index (math $index + 1); set api_key $argv[$index]
            case -h --help
                echo 'Usage: litellm_delete [FILTER] [OPTIONS]'
                echo '  With no filter, select models interactively'
                echo '  -r, --regex      Treat MODEL as a regular expression'
                echo '  --health-check   Show healthy/404 status in the selector'
                echo '  --unavailable    Only select models returning 404 (alias: --404)'
                echo '  -f, --force      Skip confirmation'
                echo '  -u, --url        Override LITELLM_MG_URL'
                echo '  -k, --api-key    Override LITELLM_MG_KEY'
                return 0
            case '*'
                echo "Error: unknown option '$argv[$index]'" >&2
                return 1
        end
        set index (math $index + 1)
    end

    __litellm_connection_error "$litellm_url" "$api_key"; or return 1
    set -l no_filter false
    if test -z "$model_name"; and test -z "$credential"; and test -z "$prefix"
        set no_filter true
    end
    if test "$no_filter" = true; and not status is-interactive; and test "$unavailable_only" != true
        echo 'Error: a filter or --unavailable is required outside an interactive shell' >&2
        return 1
    end
    if test "$no_filter" = true; and test "$force" = true; and test "$unavailable_only" != true
        echo 'Error: --force without a filter requires --unavailable' >&2
        return 1
    end

    set -l parts (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
      (__litellm_call GET "$litellm_url" "$api_key" /model/info ''))
    if test "$parts[2]" != 200
        echo "Error: could not list models (HTTP $parts[2])" >&2
        return 1
    end

    set -l matches (printf '%s\n' "$parts[1]" | jq -c \
      --arg model "$model_name" --arg credential "$credential" --arg prefix "$prefix" \
      --argjson regex "$use_regex" '
        [.data[]
         | select($credential == "" or (.litellm_params.litellm_credential_name // "") == $credential)
         | select($prefix == "" or ((.litellm_params.model // "") | startswith($prefix)))
         | select(
             $model == ""
             or ($regex and ([.model_name, .litellm_params.model, .model_info.key, .model_info.id] | map(. // "") | any(test($model))))
             or (($regex | not) and ([.model_name, .litellm_params.model, .model_info.key, .model_info.id] | map(. // "") | index($model)))
           )
         | {model_name, source: (.litellm_params.model // ""), credential: (.litellm_params.litellm_credential_name // ""), id: (.model_info.id // "")}]
      '); or return 1

    set -l count (printf '%s\n' "$matches" | jq 'length')
    if test "$count" -eq 0
        echo 'No managed models matched.'
        return 0
    end

    if test "$no_filter" = true; or test "$health_check" = true
        echo "Checking $count model(s)..." >&2
        set matches (__litellm_add_health "$matches" "$litellm_url" "$api_key"); or return 1
    end
    if test "$unavailable_only" = true
        set matches (printf '%s\n' "$matches" | jq -c '[.[] | select(.health == "404 unavailable")]')
        set count (printf '%s\n' "$matches" | jq 'length')
        if test "$count" -eq 0
            echo 'No models returned 404.'
            return 0
        end
    end

    if status is-interactive; and test -t 0; and test "$force" != true
        set matches (__litellm_select_delete_entries "$matches"); or return 1
        set count (printf '%s\n' "$matches" | jq 'length')
        if test "$count" -eq 0
            echo 'Deletion cancelled.'
            return 0
        end
    end

    printf '%s\n' "$matches" | jq -r '.[] | "  \(.health // "unchecked")  \(.model_name) [\(.credential)] ← \(.source)"'
    if test "$force" != true
        read -l -P "Delete these $count model(s)? Type yes: " confirmation
        if test "$confirmation" != yes
            echo 'Deletion cancelled.'
            return 0
        end
    end

    set -l failed 0
    for entry in (printf '%s\n' "$matches" | jq -c '.[]')
        set -l id (printf '%s\n' "$entry" | jq -r '.id')
        set -l name (printf '%s\n' "$entry" | jq -r '.model_name')
        if test -z "$id"
            echo "✗ $name has no delete ID"
            set failed (math $failed + 1)
            continue
        end
        set -l payload (jq -cn --arg id "$id" '{id: $id}')
        set -l result (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
          (__litellm_call POST "$litellm_url" "$api_key" /model/delete "$payload"))
        if test "$result[2]" = 200
            echo "✓ Deleted $name"
        else
            echo "✗ Failed to delete $name (HTTP $result[2])"
            set failed (math $failed + 1)
        end
    end
    test "$failed" -eq 0
end

function litellm_update_metadata
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l model_name
    set -l input_cost
    set -l output_cost
    set -l context_length
    set -l max_output_tokens
    set -l supports_tools
    set -l supports_reasoning

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case -m --model
                set index (math $index + 1); set model_name $argv[$index]
            case --input-cost
                set index (math $index + 1); set input_cost $argv[$index]
            case --output-cost
                set index (math $index + 1); set output_cost $argv[$index]
            case --context-length
                set index (math $index + 1); set context_length $argv[$index]
            case --max-output-tokens
                set index (math $index + 1); set max_output_tokens $argv[$index]
            case --supports-tools
                set index (math $index + 1); set supports_tools $argv[$index]
            case --supports-reasoning
                set index (math $index + 1); set supports_reasoning $argv[$index]
            case -u --url
                set index (math $index + 1); set litellm_url $argv[$index]
            case -k --api-key
                set index (math $index + 1); set api_key $argv[$index]
            case -h --help
                echo 'Usage: litellm_update_metadata -m MODEL [METADATA OPTIONS]'
                echo '  --input-cost NUMBER       Cost per input token'
                echo '  --output-cost NUMBER      Cost per output token'
                echo '  --context-length NUMBER   Context window'
                echo '  --max-output-tokens NUM   Maximum output'
                echo '  --supports-tools BOOL     true or false'
                echo '  --supports-reasoning BOOL true or false'
                echo '  -u/--url and -k/--api-key override LITELLM_MG_URL/LITELLM_MG_KEY'
                return 0
            case '*'
                echo "Error: unknown option '$argv[$index]'" >&2
                return 1
        end
        set index (math $index + 1)
    end

    __litellm_connection_error "$litellm_url" "$api_key"; or return 1
    if test -z "$model_name"
        echo 'Error: --model is required' >&2
        return 1
    end

    set -l metadata (jq -cn \
      --arg input "$input_cost" --arg output "$output_cost" \
      --arg context "$context_length" --arg max_output "$max_output_tokens" \
      --arg tools "$supports_tools" --arg reasoning "$supports_reasoning" '
        {}
        + (if $input == "" then {} else {input_cost_per_token: ($input | tonumber)} end)
        + (if $output == "" then {} else {output_cost_per_token: ($output | tonumber)} end)
        + (if $context == "" then {} else {max_tokens: ($context | tonumber)} end)
        + (if $max_output == "" then {} else {max_output_tokens: ($max_output | tonumber)} end)
        + (if $tools == "" then {} else {supports_tools: ($tools | test("^true$"; "i"))} end)
        + (if $reasoning == "" then {} else {supports_reasoning: ($reasoning | test("^true$"; "i"))} end)
      '); or begin
        echo 'Error: metadata values are invalid' >&2
        return 1
    end
    if test (printf '%s\n' "$metadata" | jq 'length') -eq 0
        echo 'Error: provide at least one metadata option' >&2
        return 1
    end

    set -l payload (jq -cn --arg model "$model_name" --argjson metadata "$metadata" \
      '{model_name: $model, metadata: $metadata}')
    set -l result (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
      (__litellm_call POST "$litellm_url" "$api_key" /model/update "$payload"))
    if test "$result[2]" = 200
        echo "✓ Updated metadata for $model_name"
        return 0
    end
    echo "✗ Metadata update failed (HTTP $result[2])" >&2
    test -n "$result[1]"; and echo "$result[1]" >&2
    return 1
end

function __litellm_catalog_usage --argument-names command display default_credential source
    echo "Usage: $command [OPTIONS]"
    echo
    echo "Fetch and register models from $display"
    echo "Source: $source"
    echo
    echo "Options:"
    echo "  -c, --credential TEXT     Credential name (default: '$default_credential')"
    echo "  -u, --url TEXT            LiteLLM API URL (env: LITELLM_MG_URL)"
    echo "  -k, --api-key TEXT        LiteLLM API key (env: LITELLM_MG_KEY)"
    if test "$command" = litellm_register_tokenrouter_free
        echo "  --tokenrouter-api-key     Token Router key (env: TOKENROUTER_API_KEY)"
    end
    echo "  -a, --all                 Register every available model without prompting"
    echo "  --no-normalize            Preserve catalog aliases exactly"
    echo "  --test-connection         Run LiteLLM connection test after registration"
    echo "  --no-health-check         Skip post-registration verification"
    echo "  --dry-run                 Select and list models without registering"
    echo "  -h, --help                Show this help message"
end

function __litellm_catalog_config --argument-names catalog
    switch $catalog
        case openrouter
            printf '%s\n' 'OpenRouter' 'OpenRouter' 'https://openrouter.ai/api/v1/models' \
              '[.data[] | select(.id | endswith(":free")) | {source: .id, public: (.id | sub(":free$"; "") | split("/") | last)}]'
        case kilo
            printf '%s\n' 'Kilo AI' 'Kilo' 'https://api.kilo.ai/api/gateway/models' \
              '[.data[] | select(.isFree == true and (.id | endswith(":free"))) | {source: .id, public: (.id | sub(":free$"; "") | split("/") | last)}]'
        case nvidia
            printf '%s\n' 'NVIDIA NIM' 'NGC' 'https://integrate.api.nvidia.com/v1/models' \
              '[.data | unique_by(.id) | .[] | select(.id | test("riva-translate|parse|reward|nvclip|calibration|gliner-pii|video-detector|deplot|content-safety|topic-control") | not) | {source: .id, public: (.id | split("/") | last)}]'
        case zenmux
            printf '%s\n' 'ZenMux AI' 'ZenMux' 'https://zenmux.ai/api/v1/models' \
              '[.data[] | select(.id | endswith("-free")) | {source: .id, public: (.id | sub("-free$"; "") | split("/") | last)}]'
        case opencode
            printf '%s\n' 'OpenCode AI' 'OpenCode' 'https://opencode.ai/zen/v1/models' \
              '[.data[] | select(.id | endswith("-free")) | {source: .id, public: (.id | sub("-free$"; "") | split("/") | last)}]'
        case tokenrouter
            printf '%s\n' 'Token Router' 'TokenRouter' 'https://api.tokenrouter.com/v1/models' \
              '[.data[] | select((.id | endswith(":free") or endswith("-free")) or (((.pricing.prompt // .pricing.input // "1") | tonumber?) == 0 and ((.pricing.completion // .pricing.output // "1") | tonumber?) == 0)) | {source: .id, public: (.id | sub("(:free|-free)$"; "") | split("/") | last)}]'
        case nous
            printf '%s\n' 'Nous Research' 'Nous' 'https://inference-api.nousresearch.com/v1/models' \
              '[.data[] | select((.id | endswith(":free")) or (((.pricing.prompt // "1") | tonumber?) == 0 and ((.pricing.completion // "1") | tonumber?) == 0)) | {source: .id, public: (.id | sub(":free$"; "") | split("/") | last)}]'
        case '*'
            echo "Error: unknown model catalog '$catalog'" >&2
            return 1
    end
end

function __litellm_fetch_catalog_models --argument-names catalog catalog_api_key
    set -l config (__litellm_catalog_config "$catalog"); or return 1
    set -l raw_json
    if test "$catalog" = tokenrouter
        if test -z "$catalog_api_key"
            echo 'Error: Token Router API key is required (set TOKENROUTER_API_KEY)' >&2
            return 1
        end
        set raw_json (curl -sS -H "Authorization: Bearer $catalog_api_key" "$config[3]")
    else
        set raw_json (curl -sS "$config[3]")
    end
    if test $status -ne 0; or test -z "$raw_json"
        echo "Error: failed to fetch models from $config[1]" >&2
        return 1
    end
    printf '%s\n' "$raw_json" | jq -c "$config[4]"
end

function __litellm_fetch_free_endpoint --argument-names endpoint provider_api_key
    set endpoint (string replace -r '/$' '' -- "$endpoint")
    if not string match -q '*/models' "$endpoint"
        set endpoint "$endpoint/models"
    end
    set -l raw_json
    if test -n "$provider_api_key"
        set raw_json (curl -sS -H "Authorization: Bearer $provider_api_key" "$endpoint")
    else
        set raw_json (curl -sS "$endpoint")
    end
    if test $status -ne 0; or test -z "$raw_json"
        echo "Error: failed to fetch $endpoint" >&2
        return 1
    end
    printf '%s\n' "$raw_json" | jq -c '
      [.data[] | select(.id | endswith(":free") or endswith("-free")) | {source: .id, public: (.id | sub("(:free|-free)$"; "") | split("/") | last)}]
    '
end

function litellm_register_free
    set -l credential
    set -l endpoint
    set -l provider_api_key
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l select_all false
    set -l dry_run false
    set -l verify health

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case -c --credential
                set index (math $index + 1); set credential $argv[$index]
            case -u --url --endpoint
                set index (math $index + 1); set endpoint $argv[$index]
            case --provider-api-key
                set index (math $index + 1); set provider_api_key $argv[$index]
            case --litellm-url
                set index (math $index + 1); set litellm_url $argv[$index]
            case --litellm-api-key
                set index (math $index + 1); set api_key $argv[$index]
            case -a --all
                set select_all true
            case --dry-run
                set dry_run true
            case --test-connection
                set verify connection
            case --no-health-check
                set verify none
            case -h --help
                echo 'Usage: litellm_register_free -c CREDENTIAL -u PROVIDER_URL [OPTIONS]'
                echo 'Registers model IDs ending in :free or -free.'
                echo '  -u accepts a base URL or full /models URL'
                echo '  --provider-api-key KEY   Optional Bearer token for the catalog'
                echo '  -a, --all                Skip model selector'
                echo '  --dry-run                Select and print without registering'
                echo '  --test-connection        Deep verification after registration'
                echo '  --no-health-check        Skip post-registration verification'
                echo '  LiteLLM connection defaults to LITELLM_MG_URL/LITELLM_MG_KEY'
                return 0
            case '*'
                echo "Error: unknown option '$argv[$index]'" >&2
                return 1
        end
        set index (math $index + 1)
    end

    if test -z "$credential"; or test -z "$endpoint"
        echo 'Error: -c CREDENTIAL and -u PROVIDER_URL are required' >&2
        return 1
    end
    set -l raw_entries (__litellm_fetch_free_endpoint "$endpoint" "$provider_api_key"); or return 1
    set -l entries '[]'
    for entry in (printf '%s\n' "$raw_entries" | jq -c '.[]')
        set -l source (printf '%s\n' "$entry" | jq -r '.source')
        set -l suggested (printf '%s\n' "$entry" | jq -r '.public')
        set -l public (__litellm_public_name "$source" "$suggested" true)
        set entries (jq -cn --argjson rows "$entries" --arg source "$source" --arg public "$public" \
          '$rows + [{source: $source, public: $public}]')
    end
    if test (printf '%s\n' "$entries" | jq 'length') -eq 0
        echo 'No :free or -free models found.'
        return 0
    end
    if test "$select_all" != true
        set entries (__litellm_select_models "$entries"); or return 1
    end
    test (printf '%s\n' "$entries" | jq 'length') -eq 0; and return 0
    if test "$dry_run" = true
        printf '%s\n' "$entries" | jq -r '.[] | "  \(.source) → \(.public)"'
        return 0
    end
    __litellm_connection_error "$litellm_url" "$api_key"; or return 1
    __litellm_register_entries "$entries" "$litellm_url" "$api_key" "$credential" "$verify"
end

function __litellm_existing_entries --argument-names litellm_url api_key credential
    set -l parts (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
      (__litellm_call GET "$litellm_url" "$api_key" /model/info ''))

    if test "$parts[2]" != 200
        echo "Error: could not check existing LiteLLM models (HTTP $parts[2])" >&2
        test -n "$parts[1]"; and echo "$parts[1]" >&2
        return 1
    end

    printf '%s\n' "$parts[1]" | jq -c --arg credential "$credential" '
      [.data[]
       | select((.litellm_params.litellm_credential_name // "") == $credential)
       | {
           source: (.litellm_params.model // ""),
           public: (.model_name // ""),
           id: (.model_info.id // "")
         }]
    '
end

function __litellm_existing_models --argument-names litellm_url api_key credential
    set -l entries (__litellm_existing_entries "$litellm_url" "$api_key" "$credential"); or return 1
    printf '%s\n' "$entries" | jq -c '[.[].source]'
end

function __litellm_remove_existing --argument-names models existing
    jq -cn --argjson models "$models" --argjson existing "$existing" \
      '$models | map(select(.source as $source | $existing | index($source) | not))'
end

function __litellm_select_models --argument-names models
    set -l count (printf '%s\n' "$models" | jq 'length')
    if test "$count" -eq 0
        echo '[]'
        return 0
    end

    # Piped/automated calls cannot answer a selector, so select everything.
    if not status is-interactive; or not test -t 0
        echo "$models"
        return 0
    end

    if not command -q fzf
        echo 'Error: interactive model selection requires fzf (brew install fzf)' >&2
        return 1
    end

    set -l choices "all\t☐ Select all"
    set -l index 1
    for label in (printf '%s\n' "$models" | jq -r '.[] | "\(.source) → \(.public)"')
        set -a choices "$index\t$label"
        set index (math $index + 1)
    end

    set -l selected (printf '%b\n' $choices | fzf \
      --multi \
      --no-sort \
      --delimiter='\t' \
      --with-nth=2.. \
      --accept-nth=1 \
      --marker='✓' \
      --pointer='›' \
      --prompt='Models › ' \
      --header='Tab: toggle  •  Ctrl-A: toggle all  •  Enter: confirm' \
      --bind='ctrl-a:toggle-all')

    if test $status -ne 0; or test (count $selected) -eq 0
        echo '[]'
        return 0
    end
    if contains -- all $selected
        echo "$models"
        return 0
    end

    printf '%s\n' $selected | jq -Rsc --argjson models "$models" '
      split("\n") | map(select(length > 0) | tonumber - 1) | unique | map($models[.])
    '
end

function __litellm_register_catalog --argument-names catalog
    set -e argv[1]
    set -l config (__litellm_catalog_config "$catalog"); or return 1
    set -l display $config[1]
    set -l credential $config[2]
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l dry_run false
    set -l select_all false
    set -l catalog_api_key "$TOKENROUTER_API_KEY"
    set -l normalize true
    set -l verify health

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case -c --credential --provider
                set index (math $index + 1); set credential $argv[$index]
            case -u --url
                set index (math $index + 1); set litellm_url $argv[$index]
            case -k --api-key
                set index (math $index + 1); set api_key $argv[$index]
            case --tokenrouter-api-key
                set index (math $index + 1); set catalog_api_key $argv[$index]
            case -a --all
                set select_all true
            case --no-normalize
                set normalize false
            case --test-connection
                set verify connection
            case --no-health-check
                set verify none
            case --dry-run
                set dry_run true
            case -h --help
                set -l command "litellm_register_$catalog"
                contains -- "$catalog" openrouter kilo zenmux opencode tokenrouter nous; and set command "$command"_free
                __litellm_catalog_usage "$command" "$display" "$config[2]" "$config[3]"
                return 0
            case '*'
                echo "Error: unknown option '$argv[$index]'" >&2
                return 1
        end
        set index (math $index + 1)
    end

    if test "$dry_run" != true
        if test -z "$litellm_url"
            echo 'Error: LiteLLM URL is required (set LITELLM_MG_URL or use -u)' >&2
            return 1
        end
        if test -z "$api_key"
            echo 'Error: API key is required (set LITELLM_MG_KEY or use -k)' >&2
            return 1
        end
    end

    echo "Fetching models from $display..." >&2
    set -l models (__litellm_fetch_catalog_models "$catalog" "$catalog_api_key"); or return 1

    set -l named_models '[]'
    for entry in (printf '%s\n' "$models" | jq -c '.[]')
        set -l source (printf '%s\n' "$entry" | jq -r '.source')
        set -l suggested (printf '%s\n' "$entry" | jq -r '.public')
        set -l public (__litellm_public_name "$source" "$suggested" "$normalize")
        set named_models (jq -cn --argjson entries "$named_models" --arg source "$source" --arg public "$public" \
          '$entries + [{source: $source, public: $public}]')
    end
    set models "$named_models"

    set -l skipped_count 0
    if test "$dry_run" != true
        set -l existing (__litellm_existing_models "$litellm_url" "$api_key" "$credential"); or return 1
        set -l before_count (printf '%s\n' "$models" | jq 'length')
        set models (__litellm_remove_existing "$models" "$existing")
        set skipped_count (math "$before_count - "(printf '%s\n' "$models" | jq 'length'))
    end

    set -l available_count (printf '%s\n' "$models" | jq 'length')
    echo "Available: $available_count; already registered for '$credential': $skipped_count" >&2
    if test "$available_count" -eq 0
        echo 'Nothing to register.' >&2
        return 0
    end

    if test "$select_all" != true
        set models (__litellm_select_models "$models"); or return 1
    end
    set -l selected_count (printf '%s\n' "$models" | jq 'length')
    if test "$selected_count" -eq 0
        echo 'No models selected.' >&2
        return 0
    end

    if test "$dry_run" = true
        printf '%s\n' "$models" | jq -r '.[] | "  \(.source) → \(.public)"'
        return 0
    end

    set -l succeeded 0
    set -l failed 0
    set -l unhealthy 0
    set index 1
    for entry in (printf '%s\n' "$models" | jq -c '.[]')
        set -l source_model (printf '%s\n' "$entry" | jq -r '.source')
        set -l public_name (printf '%s\n' "$entry" | jq -r '.public')
        echo "[$index/$selected_count] $source_model → $public_name"
        set -l parts (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
          (__litellm_register_one "$litellm_url" "$api_key" "$source_model" "$public_name" "$credential"))
        if test "$parts[2]" = 200
            echo '    ✓ Registered'
            set succeeded (math $succeeded + 1)
            if __litellm_verify_registered_model "$litellm_url" "$api_key" "$public_name" "$verify"
                test "$verify" != none; and echo '    ✓ Health check passed'
            else
                echo '    ✗ Health check failed'
                set unhealthy (math $unhealthy + 1)
            end
        else
            echo "    ✗ Failed (HTTP $parts[2])"
            test -n "$parts[1]"; and echo "    $parts[1]"
            set failed (math $failed + 1)
        end
        set index (math $index + 1)
    end

    echo
    echo "Summary: $succeeded registered, $skipped_count already present, $failed failed, $unhealthy unhealthy"
    test "$failed" -eq 0; and test "$unhealthy" -eq 0
end

function litellm_check_free
    set -l catalogs openrouter kilo zenmux opencode tokenrouter nous
    set -l litellm_url "$LITELLM_MG_URL"
    set -l api_key "$LITELLM_MG_KEY"
    set -l catalog_api_key "$TOKENROUTER_API_KEY"
    set -l credential
    set -l json false
    set -l delete false
    set -l force false

    set -l index 1
    while test $index -le (count $argv)
        switch $argv[$index]
            case openrouter kilo zenmux opencode tokenrouter nous
                set catalogs $argv[$index]
            case -c --credential --provider
                set index (math $index + 1); set credential $argv[$index]
            case -u --url
                set index (math $index + 1); set litellm_url $argv[$index]
            case -k --api-key
                set index (math $index + 1); set api_key $argv[$index]
            case --tokenrouter-api-key
                set index (math $index + 1); set catalog_api_key $argv[$index]
            case --json
                set json true
            case --delete
                set delete true
            case -f --force
                set force true
            case -h --help
                echo 'Usage: litellm_check_free [openrouter|kilo|zenmux|opencode|tokenrouter|nous] [OPTIONS]'
                echo 'Compares registered provider models with each current free catalog.'
                echo '  -c, --credential NAME    Override credential for a single catalog'
                echo '  --json                   Emit one JSON result per catalog'
                echo '  --delete                 Delete models no longer in the provider catalog'
                echo '  -f, --force              Skip deletion confirmation'
                echo '  -u/--url, -k/--api-key   Override LITELLM_MG_URL/LITELLM_MG_KEY'
                return 0
            case '*'
                echo "Error: unknown option or provider '$argv[$index]'" >&2
                return 1
        end
        set index (math $index + 1)
    end

    __litellm_connection_error "$litellm_url" "$api_key"; or return 1
    if test -n "$credential"; and test (count $catalogs) -gt 1
        echo 'Error: --credential requires one provider' >&2
        return 1
    end

    set -l stale_total 0
    for catalog in $catalogs
        set -l config (__litellm_catalog_config "$catalog"); or return 1
        set -l row_credential "$credential"
        test -z "$row_credential"; and set row_credential $config[2]

        set -l live_entries (__litellm_fetch_catalog_models "$catalog" "$catalog_api_key"); or return 1
        set -l live (printf '%s\n' "$live_entries" | jq -c '[.[].source]')
        set -l registered_entries (__litellm_existing_entries "$litellm_url" "$api_key" "$row_credential"); or return 1
        set -l registered (printf '%s\n' "$registered_entries" | jq -c '[.[].source]')
        set -l result (jq -cn \
          --arg provider "$catalog" --arg display "$config[1]" --arg credential "$row_credential" \
          --argjson live "$live" --argjson registered "$registered" --argjson entries "$registered_entries" '
            {
              provider: $provider,
              display: $display,
              credential: $credential,
              available: [$registered[] | select(. as $model | $live | index($model))],
              unavailable: [$entries[] | select(.source as $model | $live | index($model) | not)],
              unregistered: [$live[] | select(. as $model | $registered | index($model) | not)]
            }
          ')
        set stale_total (math "$stale_total + "(printf '%s\n' "$result" | jq '.unavailable | length'))

        if test "$json" = true
            echo "$result"
        else
            echo "$config[1] [$row_credential]"
            printf '%s\n' "$result" | jq -r '
              "  ✓ Available: \(.available | length)",
              "  ✗ No longer listed: \(.unavailable | length)",
              (.unavailable[]? | "    - \(.source)"),
              "  + Available but not registered: \(.unregistered | length)"
            '
        end


        set -l stale_count (printf '%s\n' "$result" | jq '.unavailable | length')
        if test "$delete" = true; and test "$stale_count" -gt 0
            set -l confirmed "$force"
            if test "$force" != true
                read -l -P "Delete these $stale_count stale $config[1] model(s)? Type yes: " answer
                test "$answer" = yes; and set confirmed true
            end
            if test "$confirmed" = true
                for stale in (printf '%s\n' "$result" | jq -c '.unavailable[]')
                    set -l id (printf '%s\n' "$stale" | jq -r '.id')
                    set -l source (printf '%s\n' "$stale" | jq -r '.source')
                    if test -z "$id"
                        echo "  ✗ Cannot delete $source: missing model ID" >&2
                        continue
                    end
                    set -l payload (jq -cn --arg id "$id" '{id: $id}')
                    set -l response (string split -m 1 '__LITELLM_HTTP_STATUS__' -- \
                      (__litellm_call POST "$litellm_url" "$api_key" /model/delete "$payload"))
                    if test "$response[2]" = 200
                        echo "  ✓ Deleted $source"
                        set stale_total (math "$stale_total - 1")
                    else
                        echo "  ✗ Failed to delete $source (HTTP $response[2])" >&2
                    end
                end
            end
        end
    end

    test "$stale_total" -eq 0
end

function litellm_register_openrouter_free; __litellm_register_catalog openrouter $argv; end
function litellm_register_kilo_free; __litellm_register_catalog kilo $argv; end
function litellm_register_nvidia; __litellm_register_catalog nvidia $argv; end
function litellm_register_zenmux_free; __litellm_register_catalog zenmux $argv; end
function litellm_register_opencode_free; __litellm_register_catalog opencode $argv; end
function litellm_register_tokenrouter_free; __litellm_register_catalog tokenrouter $argv; end
function litellm_register_nous_free; __litellm_register_catalog nous $argv; end
