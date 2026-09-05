# Aliasuri utile pentru mediul rescue (root e singurul user).
# Dropped la /etc/profile.d/rescue-aliases.sh, se incarca automat la login
# (consola locala si SSH).

alias ls='ls --color=auto'
alias grep='grep --color=auto'

alias ll='ls -lh --color=auto'
alias la='ls -lAh --color=auto'
alias l='ls -lAFh --color=auto'

alias space='lsblk -o NAME,SIZE,FSSIZE,FSUSE%,FSUSED,FSAVAIL,MOUNTPOINTS,FSTYPE | grep %'
