function pyclean --description 'Cleans py[cod] and cache dirs in the current tree'
    if command -q fd
        fd -I -H '(\.py[cod]$|__pycache__|\.(pytest_|mypy_)?cache|\.hypothesis)' -X rm -rf --
    else if command -q fdfind
        fdfind -I -H '(\.py[cod]$|__pycache__|\.(pytest_|mypy_)?cache|\.hypothesis)' -X rm -rf --
    else
        echo 'pyclean: requires fd or fdfind' >&2
        return 1
    end
end
