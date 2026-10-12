function envpick --description 'Search and manage exported environment variables'
    if not type -q fzf
        echo 'envpick: requires fzf' >&2
        return 1
    end

    set -l variable (set --names --export | fzf \
        --prompt='env> ' \
        --preview='printenv {}' \
        --preview-window=down,3,wrap)
    or return

    if test -z "$variable"
        return 0
    end

    set -l action (printf '%s\n' 'Print value' 'Edit' 'Delete' | fzf --prompt="$variable> ")
    or return

    switch "$action"
        case 'Print value'
            printenv "$variable"
        case Edit
            if string match -rq '(^PATH$|_PATH$)' -- "$variable"
                set -l current_value (string join ':' -- $$variable)
            else
                set -l current_value (string join ' ' -- $$variable)
            end
            read --prompt-str="$variable [$current_value]: " new_value
            or return
            set --global --export "$variable" "$new_value"
        case Delete
            set --erase --global "$variable"
    end
end
