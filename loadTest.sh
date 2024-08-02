#!/bin/bash
oc apply -n sonataflow-infra -f di_route.yaml

export DI_URL=$(oc -n sonataflow-infra get route sonataflow-platform-data-index-route -o yaml | yq -r .spec.host)
export UI_URL=$(oc -n rhdh-operator get route backstage-backstage -o yaml | yq -r .spec.host)
export BEARER=$(oc -n rhdh-operator get secret backstage-backend-auth-secret -o go-template='{{ .data.BACKEND_SECRET  }}' | base64 -d)

export CURRENT_TEST_FOLDER=loadTests_$(date -u +%Y-%m-%dT%T)
mkdir ${CURRENT_TEST_FOLDER}

oc -n rhdh-operator patch route backstage-backstage --type merge -p '{"metadata": { "annotations": {"haproxy.router.openshift.io/timeout": "900s"}}}'

request_ui_execute () {
  req_time=$(curl -w ' -- Status: %{http_code}; Total: %{time_total}s\n' -XPOST https://${UI_URL}/api/orchestrator/workflows/create-ocp-project/execute -H "Authorization: Bearer ${BEARER}" -d '{"operationsProjectKey":"VC","auditProjectKey":"AUD","recipients":["user:default/gabriel-farache"],"projectName":"test-gabi"}' -H 'Content-Type:application/json' 2>> ${CURRENT_TEST_FOLDER}/ui_exec_time_request_error.log)
  echo "$(date -u +%Y-%m-%dT%T.%N) - ${req_time}" >> ${CURRENT_TEST_FOLDER}/ui_exec_time_request.log
}

request_di () {
  # Without pagination
  req_time=$(curl -w ' -- Status: %{http_code}; Total: %{time_total}s\n' -XPOST -H 'Content-type: application/json' --max-time 900 https://${DI_URL}/graphql -d '{"query":"{\n  \tProcessInstances  {\n      id, \n      processName,\n      processId,\n      businessKey,\n      state,\n      start,\n      end, \n      nodes { id },\n      variables, \n      parentProcessInstance {id, processName, businessKey}\n    }\n  \n}"}' 2>> ${CURRENT_TEST_FOLDER}/di_time_request_error.log) 
   # With pagination
  #req_time=$(curl -o /dev/null -s -w 'Total: %{time_total}s\n' -XPOST -H 'Content-type: application/json' --max-time 900 https://${DI_URL}/graphql -d '{"query":"{\n  \tProcessInstances(pagination: {limit: 10 , offset: 0})  {\n      id, \n      processName,\n      processId,\n      businessKey,\n      state,\n      start,\n      end, \n      nodes { id },\n      variables, \n      parentProcessInstance {id, processName, businessKey}\n    }\n  \n}"}') 
  echo "$(date -u +%Y-%m-%dT%T.%N) - ${req_time}" >> ${CURRENT_TEST_FOLDER}/di_time_request.log
}

request_ui_overview () {
  req_time=$(curl -w ' -- Status: %{http_code}; Total: %{time_total}s\n' -XGET https://${UI_URL}/api/orchestrator/workflows/overview -H "Authorization: Bearer ${BEARER}"  2>> ${CURRENT_TEST_FOLDER}/ui_overview_time_request_error.log)
  echo "$(date -u +%Y-%m-%dT%T.%N) - ${req_time}" >> ${CURRENT_TEST_FOLDER}/ui_overview_time_request.log
}

request_ui_instances () {
  req_time=$(curl -w ' -- Status: %{http_code}; Total: %{time_total}s\n' -XGET -H "Authorization: Bearer ${BEARER}"  -H 'Content-type: application/json' --max-time 900 https://${UI_URL}/api/orchestrator/instances 2>> ${CURRENT_TEST_FOLDER}/instances_sampling_error.log) 
  echo "$(date -u +%Y-%m-%dT%T.%N) - ${req_time}" >> ${CURRENT_TEST_FOLDER}/ui_instances_time_request.log
}

request_ui_notifications () {
  req_time=$(curl -w ' -- Status: %{http_code}; Total: %{time_total}s\n' -XGET https://${UI_URL}/api/notifications -H "Authorization: Bearer ${BEARER}" -H 'Content-Type:application/json' 2>> ${CURRENT_TEST_FOLDER}/ui_notifications_time_request_error.log)
  echo "$(date -u +%Y-%m-%dT%T.%N) - ${req_time}" >> ${CURRENT_TEST_FOLDER}/ui_notifications_time_request.log
}

extract_vm_info () {
    echo -e "\nExtracting VM info before exiting...\n"
    oc -n sonataflow-infra exec deploy/sonataflow-platform-data-index-service -- jcmd 1 VM.info > ${CURRENT_TEST_FOLDER}/sonataflow-platform-data-index-service_vm.info
    oc -n sonataflow-infra exec deploy/create-ocp-project -- jcmd 1 VM.info > ${CURRENT_TEST_FOLDER}/create-ocp-project_vm.info
}

dump_heaps () {
    echo "Dumping heaps..."
    oc -n sonataflow-infra exec deploy/create-ocp-project -- jmap -dump:all,file=dump.hprof 1
    oc -n sonataflow-infra cp ${WORKFLOW_POD}:dump.hprof workflow_heap_dump.hprof
    mv workflow_heap_dump.hprof ${CURRENT_TEST_FOLDER}/workflow_heap_dump.hprof
    oc -n sonataflow-infra exec deploy/sonataflow-platform-data-index-service -- jmap -dump:all,file=dump.hprof 1
    oc -n sonataflow-infra cp ${DI_POD}:dump.hprof ${CURRENT_TEST_FOLDER}/di_heap_dump.hprof
    mv di_heap_dump.hprof ${CURRENT_TEST_FOLDER}/di_heap_dump.hprof
}

save_pod_logs () {
    echo "Saving pods logs..."
    oc -n sonataflow-infra logs ${WORKFLOW_POD} > ${CURRENT_TEST_FOLDER}/${WORKFLOW_POD}.log
    oc -n sonataflow-infra logs ${DI_POD} > ${CURRENT_TEST_FOLDER}/${DI_POD}.log
    oc -n sonataflow-infra get pod > ${CURRENT_TEST_FOLDER}/pods_status
}


compute_test_results () {
    echo "Computing tests results..."
    UI_EXEC_500=$(cat ${CURRENT_TEST_FOLDER}/ui_exec_time_request.log | grep "Status: 500" | wc -l )
    UI_EXEC_000=$(cat ${CURRENT_TEST_FOLDER}/ui_exec_time_request.log | grep "Status: 000" | wc -l )
    UI_EXEC_200=$(cat ${CURRENT_TEST_FOLDER}/ui_exec_time_request.log | grep "Status: 200" | wc -l )
    UI_EXEC_TOTAL=$(cat ${CURRENT_TEST_FOLDER}/ui_exec_time_request.log | grep "Status:" | wc -l )
    UI_EXEC_SUCCESS_RATE=$(jq -n  "${UI_EXEC_200}/${UI_EXEC_TOTAL}*100")
    echo -e "orchestrator-backend\n\ttotal requests sent: ${UI_EXEC_TOTAL}\n\tSuccess (200): ${UI_EXEC_200}\n\tError (500): ${UI_EXEC_500}\n\tError (000): ${UI_EXEC_000}\n\tSuccess Rate: ${UI_EXEC_SUCCESS_RATE}%"
}

extract_workflows_DI_state () {
    curl -XPOST -H 'Content-type: application/json' --max-time 900 https://${DI_URL}/graphql -d '{"query":"{\n  \tProcessInstances  {\n      state\n    }\n}"}' > ${CURRENT_TEST_FOLDER}/processInstanceState.json
    RUNNING_INSTANCES=$(cat ${CURRENT_TEST_FOLDER}/processInstanceState.json | jq '[.data.ProcessInstances[] | select(.state=="ACTIVE")] | length')
    ERROR_INSTANCES=$(cat ${CURRENT_TEST_FOLDER}/processInstanceState.json | jq '[.data.ProcessInstances[] | select(.state=="ERROR")] | length')
    NULL_INSTANCES=$(cat ${CURRENT_TEST_FOLDER}/processInstanceState.json | jq '[.data.ProcessInstances[] | select(.state==null)] | length')
    TOTAL_INSTANCES=$(cat ${CURRENT_TEST_FOLDER}/processInstanceState.json | jq '.data.ProcessInstances | length')
    echo -e "------- $(date -u +%Y-%m-%dT%T.%N) -------\n\nWorkflow states count:\n\tActive: ${RUNNING_INSTANCES}\n\tError: ${ERROR_INSTANCES}\n\tUnknown (null): ${NULL_INSTANCES}\n\tTotal: ${TOTAL_INSTANCES}\n" >> ${CURRENT_TEST_FOLDER}/workflows_DI_states
    echo -e "\nWorkflow states count:\n\tActive: ${RUNNING_INSTANCES}\n\tError: ${ERROR_INSTANCES}\n\tUnknown (null): ${NULL_INSTANCES}\n\tTotal: ${TOTAL_INSTANCES}\n"
}

cleanup () {
    export WORKFLOW_POD=$(oc -n sonataflow-infra get pods -l app=create-ocp-project --no-headers | awk '{ print $1 }')
    export DI_POD=$(oc -n sonataflow-infra get pods -l sonataflow.org/service=sonataflow-platform-data-index-service --no-headers | awk '{ print $1 }')
    extract_vm_info
    dump_heaps
    save_pod_logs
    compute_test_results
    extract_workflows_DI_state
}

trap cleanup EXIT

TRIGGER_SAMPLE_LIMIT=240
CNT=${TRIGGER_SAMPLE_LIMIT}
START=`date +%s`
while [ $(( $(date +%s) - 28800 )) -lt $START ]
do
  echo "$(date -u +%Y-%m-%dT%T) - Sending 2 requests"
  request_ui_execute &
  request_ui_execute &
  sleep 1s
  CNT=$(expr ${CNT} + 2)
  if [ "${CNT}" -gt "${TRIGGER_SAMPLE_LIMIT}" ]
  then
    echo "$(date -u +%Y-%m-%dT%T) - Sampling DI and UI instances request time"
    CNT=0
    request_di &
    request_ui_instances &
    request_ui_notifications &
    extract_workflows_DI_state &
  fi
done
cleanup
