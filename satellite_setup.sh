#!/bin/bash

export LOCALE=C

if [ "$1" = "" ]; then 
  echo "USAGE: $0 <cfg.env>"; exit 1
fi

if [ ! -f "$1" ]; then 
  echo "ERROR: Configuration file $1 does not exist"; exit 1
else 
  CFGFILE=$1
fi

cnt=`egrep -c "^ORG_NAME" $CFGFILE`
if [ ${cnt} -eq 0 ]; then 
  echo "ERROR: $1 is not a valid configuration file"; exit 1
else
  . $CFGFILE
fi

mkdir -p /root/.hammer
chmod 600 /root/.hammer

HFILE="/root/.hammer/cli_config.yml"

echo ":modules:"                             >  $HFILE
echo "   - hammer_cli_foreman"               >> $HFILE
echo ":foreman:"                             >> $HFILE
echo "  :host: 'https://sat61.rhlab.local/'" >> $HFILE
echo "  :username: '${SAT_ADMIN}'"           >> $HFILE
echo "  :password: '${SAT_PASS}'"            >> $HFILE

cnt=`hammer organization list | grep -c " ${ORG_NAME} "`
if [ ${cnt} -eq 0 ]; then
  hammer organization create --name="${ORG_NAME}" --label=${ORG_LABEL}
  org_id=`hammer organization list | grep " ${ORG_NAME} " | awk '{ print $1 }'`
fi

echo "Creating Organization: ${ORG_NAME}"
cnt=`hammer user list | grep -c " rhadmin "`
if [ ${cnt} -eq 0 ]; then
  hammer user create --organizations "${ORG_NAME}" --login ${ORG_ADMIN} --mail "${ORG_ADMIN}@${SATELLITE}" --password="${ORG_PASS}" --auth-source-id 1 --admin 1 --default-organization-id ${org_id}
hammer organization add-user --user=${ORG_ADMIN} --name="${ORG_NAME}"
fi

echo "Create lifecycle environment: DEV -> QE -> PROD"
hammer lifecycle-environment info --name DEV --organization="${ORG_NAME}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  hammer lifecycle-environment create --name='DEV' --prior='Library' --organization="${ORG_NAME}"
fi

hammer lifecycle-environment info --name QE --organization="${ORG_NAME}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  hammer lifecycle-environment create --name='QE' --prior='DEV' --organization="${ORG_NAME}"  
fi

hammer lifecycle-environment info --name PROD --organization="${ORG_NAME}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  hammer lifecycle-environment create --name='PROD' --prior='QE' --organization="${ORG_NAME}"  
fi

if [ ! -f ${MANIFEST} ]; then 
  echo "ERROR: Manifest: ${MANIFEST} not found, aborting"; exit 0
fi

echo "Upload manifest: ${MANIFEST} (created in RH Portal)"
# Upload our manifest.zip (created in RH Portal) to our org
# hammer subscription list --organization "Red Hat Demo"
cnt=`hammer subscription list --organization "${ORG_NAME}" | egrep -v "Red Hat Enterprise Linux Server|---|NAME" | wc -l`
if [ ${cnt} -eq 0 ]; then
  hammer subscription upload --file ${MANIFEST} --organization="${ORG_NAME}"
fi

# --- DUMP PRODUCTS ---
SUBLIST=`hammer subscription list --organization "${ORG_NAME}" | awk -F'|' '{ print $8 }' | egrep -v "ID|-" | awk '{ print $1 }'`

for n in $SUBLIST; do
  hammer product list --organization "${ORG_NAME}" --subscription-id ${n} --per-page 1000 | grep -v "\--" | \
  awk -F'|' '{ printf("%s:%s\n",$1, $2 )}' | sed -e 's/^ //g' -e 's/: /:/g' -e 's/  :/:/g' -e 's/ :/:/g' -e 's/  *$//g'  > /tmp/id_${n}
done

# --- CREATE PRODUCTS / REPOSITORIES ---
for ppp in `egrep "^PRODUCT" $CFGFILE | awk -F'|' '{ print $2 }' | sort | uniq | sed 's/ /_@_/g'`; do
  prd=`echo $ppp | sed 's/_@_/ /g'`
  pid=`egrep ":${prd}$" /tmp/id_* | head -1 | awk -F':' '{ print $2 }'`
  mod=`grep "PRODUCT|${prd}|" $CFGFILE | awk -F'|' '{ print $3 }' | head -1`
  echo "Creating Product: $prd ID: ${pid}"
  hammer product info --name "$prd" --organization="${ORG_NAME}" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    hammer product create --name "$prd" --organization "${ORG_NAME}"
  fi

  if [ "${mod}" = "REPOCREATE" ]; then
    for rrr in `grep "PRODUCT|${prd}|" $CFGFILE | awk -F'|' '{ print $4 }' | sort | uniq | sed 's/ /_@_/g'`; do
      rep=`echo $rrr | sed 's/_@_/ /g'`

      echo "  adding Repository: $rep"
      typ=`grep "PRODUCT|${prd}|REPOCREATE|${rep}|" $CFGFILE | awk -F'|' '{ print $5 }' | head -1`
      url=`grep "PRODUCT|${prd}|REPOCREATE|${rep}|" $CFGFILE | awk -F'|' '{ print $6 }' | head -1`

      if [ "${typ}" = "docker" ]; then
        ups=`grep "PRODUCT|${prd}|REPOCREATE|${rep}|" $CFGFILE | awk -F'|' '{ print $7 }' | head -1`
        hammer repository create --name="${rep}" --organization "${ORG_NAME}" --product="${prd}" --content-type="${typ}" --publish-via-http=true \
          --url="${url}" --docker-upstream-name $ups  
      fi

      if [ "${typ}" = "yum" ]; then
        hammer repository create --name="${rep}" --organization "${ORG_NAME}" --product="${prd}" --content-type="${typ}" --publish-via-http=true \
         --url="${url}" > /dev/null 2>&1
      fi

      if [ "${typ}" = "puppet" ]; then
        hammer repository create --name="${rep}" --organization "${ORG_NAME}" --product="${prd}" --content-type="${typ}" --publish-via-http=true \
         --url="${url}" > /dev/null 2>&1
      fi
    done
  fi

  if [ "${mod}" = "REPOSET1" ]; then
    for rrr in `grep "PRODUCT|${prd}|" $CFGFILE | awk -F'|' '{ print $4 }' | sort | uniq | sed 's/ /_@_/g'`; do
      rep=`echo $rrr | sed 's/_@_/ /g'`

      echo "  adding Repository: $rep"
      arc=`grep "PRODUCT|${prd}|REPOSET|${rep}|" $CFGFILE | awk -F'|' '{ print $5 }' | head -1`
      typ=`grep "PRODUCT|${prd}|REPOSET|${rep}|" $CFGFILE | awk -F'|' '{ print $6 }' | head -1`

      hammer repository-set enable --organization "${ORG_NAME}" --product-id $pid  --basearch="${arc}" --releasever="${typ}" --name "${rep}" > /dev/null 2>&1
    done
  fi
done

# --- CREATE CONTENT VIEW ---
for ccc in `egrep "^CV" $CFGFILE | awk -F'|' '{ print $2 }' | sort | uniq | sed 's/ /_@_/g'`; do
  ctv=`echo $ccc | sed 's/_@_/ /g'`
  echo "Creating ContentView: $ctv"
  hammer content-view info --name "${ctv}" --organization="${ORG_NAME}" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    hammer content-view create --name "${ctv}" --organization "${ORG_NAME}" > /dev/null 2>&1
  fi

  for ppp in `egrep "^CV" $CFGFILE | awk -F'|' '{ print $3 }' | sort | uniq | sed 's/ /_@_/g'`; do
    prd=`echo $ppp | sed 's/_@_/ /g'`
    str=`grep "CV|${ctv}|${prd}|" $CFGFILE | awk -F'|' '{ print $4 }' | head -1`
    echo "  adding Repository: $prd (${str})"
    for n in $(hammer --csv repository list --organization "${ORG_NAME}" --product "${prd}" | \
      egrep "${str}" | awk -F, {'print $1'} | grep -vi '^ID'); do

      hammer content-view add-repository --name "${ctv}" --organization "${ORG_NAME}" --repository-id ${n} > /dev/null 2>&1
    done
  done
done

# --- CREATE HOST-GROUP ---
# hammer hostgroup create --help


