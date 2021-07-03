# Release Instructions

# 0. Triage all agent release tasks
(Last updated 4/28/2021)

A few weeks before the agent release, create a story on the scrum board. Add tasks for all changes which need to go into the next release (look for tasks from the livesite story). A week or so before the release go through the task list with the team and triage the tasks (move anything which will not go into the release into the story for the next release).

# 1. Production agent image and automatic deployment to CIPROD cluster
(Last updated 4/23/2021)

Here are the high-level instructions to get the CIPROD`<MM><DD><YYYY>` image for the production release
1. create feature branch from ci_dev
   - update the following:
      <!--      > Note: This required since Azure Dev Ops pipeline doesnt support --build-arg yet to automate this.    -- What does this line mean? -->
      - Ensure IMAGE_TAG updated with release candiate image tag in kubernetes/linux/Dockerfile and kubernetes/windows/Dockerfile
      - Update build version (dockerProviderVersion) and date in build/version
      - Update the image tag and dockerProviderVersion, and any other deployment changes, in kubernetes/omsagent.yaml
      - Update the chart version in charts/azuremonitor-containers/Chart.yaml
      - Update the image tag and dockerProviderVersion version in charts/azuremonitor-containers/values.yaml 
      - Release notes
      - Note: do not updatescripts/onboarding/managed/enable-monitoring.ps1, scripts/onboarding/managed/enable-monitoring.sh, or scripts/onboarding/managed/upgrade-monitoring.sh yet
   - Create a PR to merge these changes back into ci_dev
2. Changes in ci_dev are automatically deployed to the CIDEV cluster (in the build subscription) so validate E2E to make sure everthing works
3. <a name="create_ci_prod_pr_anchor">If</a> everything validated in DEV, make a release branch off ci_prod, pull in changes from ci_dev, then make a PR to merge the release branch back into ci_prod. Request the dev team review the PR but don't merge it yet.
4. Go to the [release pipeline](https://github-private.visualstudio.com/microsoft/_releaseDefinition?definitionId=11&_a=environments-editor-preview) and update the variables with the new chart version and image tag
   1. From the release pipeline overview screen, navigate to variables -> Variable groups -> manage variable groups. Create a new variable group with the following variables:
      - CIHELMCHARTVERSION <VersionValue> # For example, 2.7.4
      - CIImageTagSuffix <ImageTag> # ciprod08072020 or ciprod08072020-1 etc.
   2. Go back to the release pipeline overview screen, navigate to variables -> Variable groups -> Link variable group, and select the variable group you just created
   3. Save the pipeline
5. Merge the PR you created [before the last step](#create_ci_prod_pr_anchor) into ci_prod. This will trigger automatic deployment of latest bits to CIPROD cluster with CIPROD`<MM><DD><YYYY>` image to test and scale cluters, AKS, AKS-Engine
   - Monitor the release [here](https://github-private.visualstudio.com/microsoft/_build?definitionId=243). The build pipeline is not stable yet, so make sure it completes sucessfully
   - Note: production image automatically pushed to CIPROD Public cloud ACR which will inturn replicated to Public cloud MCR.
6. Validate all the scenarios against clusters in build subscription and scale clusters. 
   - Deploy latest omsagent yaml with release candidate agent image in to supported k8s versions and validate all the critical scenarios. In perticular, throughly validate the updates going as part of this release and also make sure no regressions. If  this passes, deploy onto scale cluster and  validate perf and scale aspects. Scale cluster in AME cloud and co-ordinate with agent team who has access to this cluster to deploy the release candiate onto this cluster.
7. Delete the scale cluster when you are done validating (it's in AME)


# 2. Production Image to MCR CN for Azure China Cloud

No action required here, images are automatically synched to MCR CN from Public cloud MCR.

# 3. Release of the agent

## 3.1. AKS
(Last updated 5/18/2021)

1. Update the image in the AKS Agent Baker (use [this PR as a reference for linux](https://github.com/Azure/AgentBaker/pull/775) and [this PR as a reference for windows](https://github.com/Azure/AgentBaker/pull/813)). The AKS agent is built every Friday at 8:00 PM  (as of 4/23/2021, may change in the future)
2. Update the agent version in the AKS RP ([use this PR as a reference](https://msazure.visualstudio.com/CloudNativeCompute/_git/aks-rp/pullrequest/4425425)). Make this PR on Monday following the Agent Baker PR.

   Most of the files in the reference PR are auto-generated templates used for unit tests. They can be manually updated or auto-generated. The auto-generation tool doesn't always work though, sometimes it generates results that fail AKS tests. It is known to work with helm 2.12.3, please update this section if you get it working.
   ```
   # from the base directory of the aks-rp repository
   cd ccp\charts\kube-control-plane\tests
   Set RENDER_SNAPSHOTS=true
   go test .
   ```

3. update [this dashboard](https://ms.portal.azure.com/#@microsoft.onmicrosoft.com/dashboard/arm/subscriptions/13d371f9-5a39-46d5-8e1b-60158c49db84/resourcegroups/dashboards/providers/microsoft.portal/dashboards/011897c2-1ea6-4e21-bc8e-2c835fe40024). About half way down is a chart called Latest "LINUX agent (ciprod________) - Cluster count" and "Latest Windows agent (win-ciprod________) - Cluster count". Remove the oldest pair of charts and add new ones for the agent version about to roll out. This is so we can track the rollout.

Congratulations! A new agent version will roll out with the next AKS release. See instructions for monitoring its progress in [section 4](#monitor_anchor)


### Hotfix process:
See (this link)[https://msazure.visualstudio.com/CloudNativeCompute/_wiki/wikis/CloudNativeCompute.wiki/20221/Release-Hotfix?anchor=hotfix-process] for instructions on how to make hotfixes. A few things to keep in mind:
   * AKS prefers to roll back instead of roll forward. It's possible to roll back to an agent image in the agent baker, not really possible to roll forward to a new image.
   


## 3.2. Arc for Kubernetes 

Wait for the AKS rollout to go for about a week before starting other platforms. (and monitor to make sure nothing breaks)

An Ev2 pipeline is used to deploy the chart of the Arc K8s Container Insights Extension as per Safe Deployment Process. 
Here is the high level process

1. Specify chart version of the release candidate and trigger [container-insights-arc-k8s-extension-ci_prod-release](https://github-private.visualstudio.com/microsoft/_release?_a=releases&view=all)
2. Get the approval from one of team member for the release
3. Once the approved, release should be triggered automatically 
4. use `cimon-arck8s-eastus2euap` for validating latest release in canary region
5. TBD - Notify vendor team for the validation on all Arc K8s supported platforms


## 3.3. Microsoft Charts Repo release for On-prem K8s

Since HELM charts repo being deprecated, Microsoft charts repo being used for HELM chart release of on-prem K8s clusters. 
To make chart release PR, fork [Microsoft-charts-repo]([https://github.com/microsoft/charts/tree/gh-pages) and make the PR against `gh-pages` branch of the upstream repo. 

Refer PR - https://github.com/microsoft/charts/pull/23 for example.
Once the PR merged, latest version of HELM chart should be available in couple of mins in https://microsoft.github.io/charts/repo and https://artifacthub.io/.

Instructions to create PR

1. create helm package for the release candidate 
   ```
   git clone git@github.com:microsoft/Docker-Provider.git
   git checkout ci_prod
   cd ~/Docker-Provider/charts/azuremonitor-containers # this path based on where you have cloned the repo
   helm package . 
   ```

2. clone your fork repo and checkout gh_pages branch # gh_pages branch used as release branch 
   ```
   cd ~ 
   git clone <your-forked-repo-of-microsoft-charts-repo>
   cd  ~/charts # assumed the root dir of the clone is charts
   git checkout gh_pages
   ```

3. copy release candidate helm package 
   ```
   cd ~/charts/repo/azuremonitor-containers 
   # update chart version value with the version of chart being released
   cp ~/Docker-Provider/charts/azuremonitor-containers/azuremonitor-containers-<chart-version>.tgz  .  
   cd ~/charts/repo
   # update repo index file 
   helm repo index  .
   ```
    
4. Review the changes and make PR. Please note, you may need to revert unrelated changes automatically added by `helm repo index .` command



## 3.4. AKS-Engine

Make PR against [AKS-Engine](https://github.com/Azure/aks-engine). Refer PR https://github.com/Azure/aks-engine/pull/2318

Once that is done, update chart version in scripts/onboarding/managed/enable-monitoring.ps1, scripts/onboarding/managed/enable-monitoring.sh, and scripts/onboarding/managed/upgrade-monitoring.sh


# 4. Monitor agent roll-out status

<a name="monitor_anchor">In</a> Container Insights Agent (AKS) telemetry dashboard, update the agent roll status by  region chart with released agent image and track rollout status. If you see any issues with agent rollout, reach out AKS on-call team for the help on investigation and understanding whats going on.




# Problems:
(Last updated 4/26/2021)

- ciprod-rc-aks16-weu - naming makes no sense. we should rename that cluster. also it says aks16 so k8s version 16 is deprecated. i remember i upgraded it to latest when i deployed in jan
- Deployment to scale cluster is broken, cluster API server is unresponsive (kubectl can't communicate)
- deployment pipeline doesn't clean up old scale clusters, two are still running since March release (that's an expensive thing to not clean up)
- Permission errors when updating the variable group in the deployment pipeline. (Vishwa can't edit the pipeline variables)
- FIXED(?) Windows build fails on finalize step. (TODO: check cdpx email chain later for updates/fixes) (This was not an issue in the 05122021 release, not sure if we changed someting or if a platform bug was fixed. If it works on the next release then delete this problem)
