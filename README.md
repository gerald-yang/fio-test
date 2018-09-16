# fio-test

Provide heat template to run fio autotest in user_data.

Step:
1. Run builder.sh to produce test.sh
2. Copy test.sh and fio-test.yaml to openstack busybox pod
3. Create stack by fio-test.yaml
