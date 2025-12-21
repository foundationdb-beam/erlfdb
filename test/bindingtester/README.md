# Binding Tester | erlfdb

## Updating FoundationDB Version

1. Checkout foundationdb at the same tag as what's supported by the GitHub action with `bindingtester: true`
2. `git apply /path/to/erlfdb/test/bindingtester/foundationdb.patch` and `git stash`
3. `git pull` and checkout the desired new tag
4. `git stash pop` and inspect the changes
5. `git diff > /path/to/erlfdb/test/bindingtester/foundationdb.patch`
6. Update the ci.yml GitHub action with the new target FoundationDB version.

## Running the binding tester locally at a particular seed

1. Download and extract the tar.gz from the FoundationDB releases (see ci.yml) to `foundationdb`
2. `cp test/bindingtester/foundationdb.patch foundationdb`
3. `python3 -mvenv bindingtester_venv` && `source bindingtester_venv/bin/activate`
4. `cd foundationdb`
5. `sed "s:USER_SITE_PATH:$(python -c "import site; print(site.getsitepackages()[0])"):g" foundationdb.patch | patch -p1`
6. `cd ..`
7. `pip3 install -Iv foundationdb==7.3.62`
8. `ERL_LIBS=_build/test/lib/erlfdb foundationdb/bindings/bindingtester/bindingtester.py erlang --test-name api --num-ops 1000 --compare python --logging-level DEBUG --seed 12345`
