# An agent chosen when the machine was installed (install.toml's [desktop]
# agent) can't be installed with the system: it needs a network and the
# user's own tools. Offer it at first login instead of the generic invitation.
# A click installs it in a floating terminal and makes it the default, exactly
# as choosing it from the menu does.
chosen="$HOME/.local/state/omarchy/first-run-agent"
[[ -s $chosen ]] || exit 0

read -r agent <"$chosen"
rm -f "$chosen"

if [[ -n $agent && -z $(omarchy-default-agent) ]]; then
  omarchy-notification-send -u critical -g 󰚩 "Install $agent" \
    "Chosen when this machine was installed. Click to install it." \
    --exec omarchy-launch-floating-terminal-with-presentation omarchy-default-agent --install "$agent"
fi
