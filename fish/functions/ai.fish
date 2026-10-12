function ai --description 'Chat with an OpenAI-compatible model'
    if not type -q ai-chat
        echo 'ai: ai-chat is missing; rerun the dotfiles setup script' >&2
        return 1
    end

    set -l base_url "$AI_BASE_URL"
    if test -z "$base_url"
        read --prompt-str='API base URL [https://api.openai.com/v1]: ' base_url
        or return 1
        if test -z "$base_url"
            set base_url https://api.openai.com/v1
        end
    end

    set -l model "$AI_MODEL"
    if test -z "$model"
        read --prompt-str='Model [gpt-4o-mini]: ' model
        or return 1
        if test -z "$model"
            set model gpt-4o-mini
        end
    end

    set -l api_key "$AI_API_KEY"
    if test -z "$api_key"
        read --silent --prompt-str='API key (leave blank for local endpoints): ' api_key
        or return 1
        printf '\n'
    end

    env AI_BASE_URL="$base_url" AI_MODEL="$model" AI_API_KEY="$api_key" ai-chat
end
