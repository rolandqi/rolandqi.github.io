git add *
git commit -m "daily auto push"
git push --recurse-submodules=check --progress "origin" refs/heads/master:refs/heads/master
timeout /T 5