#!/bin/bash
oc create -f https://download.elastic.co/downloads/eck/2.13.0/crds.yaml
oc apply -f https://download.elastic.co/downloads/eck/2.13.0/operator.yaml
oc adm pod-network make-projects-global elastic-system
oc new-project elastic # creates the elastic project
oc apply -f es-oc.yaml
