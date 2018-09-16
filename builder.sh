#!/bin/bash

tar cf config.json.tar config.json
cat autotest.sh config.json.tar > test.sh
chmod +x test.sh
