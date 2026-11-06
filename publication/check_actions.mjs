import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
const renovateRoot = resolve(process.env.RENOVATE_ROOT ?? 'node_modules/renovate');
const root = resolve(renovateRoot, 'dist') + '/';
const renovateVersion = JSON.parse(readFileSync(resolve(renovateRoot, 'package.json'), 'utf8')).version;
const localDir = mkdtempSync(resolve(tmpdir(), 'renovate-actions-fixture-'));
const load = p => import(pathToFileURL(root+p));
const {GlobalConfig} = await load('config/global.js');
GlobalConfig.set({localDir});
const {getConfig} = await load('config/defaults.js');
const {applyPackageRules} = await load('util/package-rules/index.js');
const {lookupUpdates} = await load('workers/repository/process/lookup/index.js');
const {GithubGraphqlDatasourceFetcher} = await load('util/github/graphql/datasource-fetcher.js');
const {adapter: tagsAdapter} = await load('util/github/graphql/query-adapters/tags-query-adapter.js');
const {adapter: releasesAdapter} = await load('util/github/graphql/query-adapters/releases-query-adapter.js');
const {extractPackageFile} = await load('modules/manager/github-actions/extract.js');
const {resetCache} = await load('util/cache/repository/index.js');
const preset = JSON.parse(readFileSync(new URL('../publication-age-actions.json', import.meta.url), 'utf8'));
let tags=[], releases=[];
GithubGraphqlDatasourceFetcher.query = async (config,http,adapter) => structuredClone(adapter.key.includes('github-tags') ? tags : releases);
function seed({young=false,missing=false,retag=false}={}) {
 const old='2020-01-01T00:00:00.000Z', fresh=new Date().toISOString();
 tags = [
  {version:'v1',hash:'1'.repeat(40),releaseTimestamp:old},
  {version:'v1.0.0',hash:'1'.repeat(40),releaseTimestamp:old},
  {version:'v1.1.0',hash:(retag?'9':'2').repeat(40),releaseTimestamp:old},
  {version:'v2',hash:'3'.repeat(40),releaseTimestamp:old},
  {version:'v2.0.0',hash:'3'.repeat(40),releaseTimestamp:old},
  {version:'v3.0.0',hash:'4'.repeat(40),releaseTimestamp:old}
 ];
 releases = [
  {version:'v1.0.0',releaseTimestamp:old},
  ...(missing?[]:[{version:'v1.1.0',releaseTimestamp:young?fresh:old}]),
  {version:'v2.0.0',releaseTimestamp:young?fresh:old}
 ];
}
async function cfg(value,extra={}) {
 const workflow=`name: test\non: push\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@${'1'.repeat(40)} # ${value}\n`;
 const extracted=await extractPackageFile(workflow,'.github/workflows/test.yml',{});
 assert.ok(extracted?.deps?.length);
 const dep=extracted.deps.find(d=>d.depName==='actions/checkout');
 assert.equal(dep.currentValue,value.split('+')[0]);
 return applyPackageRules({...getConfig(),...dep,manager:'github-actions',packageFile:'.github/workflows/test.yml',packageName:'fixture/'+value+'/'+JSON.stringify(extra),minimumReleaseAge:'3 days',minimumReleaseAgeBehaviour:'timestamp-optional',internalChecksFilter:'strict',rangeStrategy:'pin',pinDigests:true,packageRules:preset.packageRules,...extra},'test');
}
const results=[];
for(const value of ['v1.0.0','1.0.0','v1.2.3-beta.1','v1.2.3+build.4','v1.2.3-rc.1+build.7']) {
 const c=await cfg(value); assert.equal(c.datasource,'github-releases'); assert.equal(c.versioning,'github-actions'); results.push({case:'exact-version match',value});
}
// This manager strips build metadata from extracted comments. Exercise the
// complete value explicitly too, so extraction cannot hide a matching defect.
const metadataValue = 'v1.2.3-rc.1+build.7';
assert.equal((await cfg(metadataValue, {currentValue:metadataValue})).datasource, 'github-releases');
results.push({case:'complete prerelease plus build metadata matches',value:metadataValue});
for(const value of ['v1','v1.2']) { const c=await cfg(value); assert.equal(c.datasource,'github-tags'); results.push({case:'floating alias unchanged',value}); }
const firstParty=await cfg('v1.0.0',{packageName:'powerhome/example',depName:'powerhome/example'}); assert.equal(firstParty.datasource,'github-tags');
results.push({case:'first-party unchanged'});
const branch=await cfg('main'); assert.equal(branch.datasource,'github-digest'); results.push({case:'branch unchanged'});
seed(); resetCache(); const stable=(await lookupUpdates(await cfg('v1.0.0'))).unwrap().val;
assert.ok(stable.updates.some(u=>u.newValue==='v1.1.0'&&u.newDigest==='2'.repeat(40)&&!u.pendingChecks));
assert.ok(stable.updates.some(u=>u.newValue==='v2.0.0'&&u.newDigest==='3'.repeat(40)&&!u.pendingChecks));
assert.ok(!stable.updates.some(u=>u.newValue==='v3.0.0'));
results.push({case:'minor and major published updates keep SHA pins; unpublished v3 excluded',updates:stable.updates});
seed({young:true}); resetCache(); const young=(await lookupUpdates(await cfg('v1.0.0',{packageName:'fixture/young'}))).unwrap().val;
assert.ok(young.updates.filter(u=>u.newValue!=='v1.0.0').every(u=>u.pendingChecks)); results.push({case:'recent publications held',updates:young.updates});
seed({missing:true}); resetCache(); const missing=(await lookupUpdates(await cfg('v1.0.0',{packageName:'fixture/missing'}))).unwrap().val;
assert.ok(!missing.updates.some(u=>u.newValue==='v1.1.0')); results.push({case:'missing release excluded',updates:missing.updates});
seed({retag:true}); resetCache(); const retag=(await lookupUpdates(await cfg('v1.1.0',{packageName:'fixture/retag',currentDigest:'2'.repeat(40)}))).unwrap().val;
assert.ok(retag.updates.some(u=>u.updateType==='digest'&&u.newDigest==='9'.repeat(40)));
results.push({case:'retag SHA refresh retained; age remains original publishedAt (known limitation)',updates:retag.updates});
// Compare the complete lookup outcome to native behavior for aliases.
for (const value of ['v1', 'v1.2']) {
 seed(); resetCache();
 const c = await cfg(value, {packageName:'fixture/alias-'+value});
 const withPreset = (await lookupUpdates(c)).unwrap().val;
 resetCache();
 const withoutPreset = (await lookupUpdates({...c, packageRules:[]})).unwrap().val;
 assert.deepEqual(withPreset, withoutPreset);
 results.push({case:'native alias lookup preserved',value});
}
// A missing current-version Release cannot authorize a changed source digest.
seed({missing:true}); resetCache();
const missingDigest = (await lookupUpdates(await cfg('v1.1.0', {packageName:'fixture/missing-digest',currentDigest:'8'.repeat(40)}))).unwrap().val;
assert.equal(missingDigest.skipReason, 'invalid-value');
assert.deepEqual(missingDigest.updates, []);
results.push({case:'missing current-version release blocks digest update'});
// Equivalent semantic versions must not lend a different exact tag their age.
for (const [current, alternate] of [
 ['v1.1.0', '1.1.0'],
 ['v1.1.0', 'V1.1.0'],
 ['1.1.0', 'v1.1.0'],
 ['v1.1.0', 'v1.1'],
 ['v1.1.0', 'v1.1.0+old'],
 ['v1.1.0+new', 'v1.1.0+old'],
 ['v1.1.0-rc.1', 'v1.1-rc.1'],
]) {
 const old='2020-01-01T00:00:00.000Z', fresh=new Date().toISOString();
 tags=[{version:current,hash:'c'.repeat(40)},{version:alternate,hash:'b'.repeat(40)}];
 const exact={version:current,releaseTimestamp:fresh};
 const equivalent={version:alternate,releaseTimestamp:old};
 for (const rows of [[equivalent,exact],[exact,equivalent]]) {
  releases=rows; resetCache();
  const result=(await lookupUpdates(await cfg(current,{currentValue:current,currentDigest:'8'.repeat(40)}))).unwrap();
  assert.ifError(result.err);
  assert.ok(result.val.updates.some(u=>u.updateType==='digest'&&u.newValue===current&&u.newDigest==='c'.repeat(40)&&u.pendingChecks), `fresh exact tag must wait: ${current} / ${alternate}`);
 }
 releases=[equivalent]; resetCache();
 const missingExact=(await lookupUpdates(await cfg(current,{currentValue:current,currentDigest:'8'.repeat(40)}))).unwrap();
 assert.ifError(missingExact.err);
 assert.deepEqual(missingExact.val.updates,[], `missing exact Release must block: ${current} / ${alternate}`);
 releases=[{...equivalent,releaseTimestamp:fresh},{...exact,releaseTimestamp:old}]; resetCache();
 const oldExact=(await lookupUpdates(await cfg(current,{currentValue:current,currentDigest:'8'.repeat(40)}))).unwrap();
 assert.ifError(oldExact.err);
 assert.ok(oldExact.val.updates.some(u=>u.updateType==='digest'&&u.newValue===current&&u.newDigest==='c'.repeat(40)&&!u.pendingChecks), `old exact Release remains usable: ${current} / ${alternate}`);
 results.push({case:'exact tag publication evidence isolated',current,alternate});
}
// Adding a first SHA pin requires the same exact-tag publication evidence.
tags=[{version:'v1.1.0',hash:'c'.repeat(40)},{version:'1.1.0',hash:'b'.repeat(40)}];
releases=[{version:'1.1.0',releaseTimestamp:'2020-01-01T00:00:00.000Z'},{version:'v1.1.0',releaseTimestamp:new Date().toISOString()}];
resetCache();
const pendingPin=(await lookupUpdates(await cfg('v1.1.0',{currentDigest:undefined}))).unwrap();
assert.ifError(pendingPin.err);
assert.ok(pendingPin.val.updates.some(u=>u.updateType==='pinDigest'&&u.newDigest==='c'.repeat(40)&&u.pendingChecks));
releases=releases.filter(r=>r.version!=='v1.1.0'); resetCache();
const missingPin=(await lookupUpdates(await cfg('v1.1.0',{currentDigest:undefined}))).unwrap();
assert.ifError(missingPin.err);
assert.deepEqual(missingPin.val.updates,[]);
results.push({case:'initial SHA pin requires exact tag publication'});
// Version upgrades retain their exact tag spelling and age their own Release.
for (const [current, next, alternate] of [
 ['v1.0.0','v1.1.0','1.1.0'],
 ['1.0.0','1.1.0','v1.1.0'],
 ['v1.0.0+build.1','v1.1.0+build.1','v1.1.0+build.2'],
]) {
 const old='2020-01-01T00:00:00.000Z', fresh=new Date().toISOString();
 tags=[{version:current,hash:'1'.repeat(40)},{version:next,hash:'2'.repeat(40)},{version:alternate,hash:'3'.repeat(40)}];
 releases=[{version:current,releaseTimestamp:old},{version:next,releaseTimestamp:fresh},{version:alternate,releaseTimestamp:old}];
 resetCache();
 const pending=(await lookupUpdates(await cfg(current,{currentValue:current}))).unwrap();
 assert.ifError(pending.err);
 assert.ok(pending.val.updates.some(u=>u.newValue===next&&u.newDigest==='2'.repeat(40)&&u.pendingChecks));
 releases=[{version:current,releaseTimestamp:old},{version:next,releaseTimestamp:old},{version:alternate,releaseTimestamp:fresh}];
 resetCache();
 const mature=(await lookupUpdates(await cfg(current,{currentValue:current}))).unwrap();
 assert.ifError(mature.err);
 assert.ok(mature.val.updates.some(u=>u.newValue===next&&u.newDigest==='2'.repeat(40)&&!u.pendingChecks));
 releases=releases.filter(r=>r.version!==next); resetCache();
 const missingUpgrade=(await lookupUpdates(await cfg(current,{currentValue:current}))).unwrap();
 assert.ifError(missingUpgrade.err);
 assert.ok(!missingUpgrade.val.updates.some(u=>u.newValue===next||u.newValue===alternate));
 results.push({case:'version upgrade uses exact published tag',current,next});
}
const tagRow=tagsAdapter.transform({version:'v1.0.0',target:{type:'Commit',oid:'1'.repeat(40),releaseTimestamp:'2020-01-01T00:00:00.000Z'}});
assert.equal(tagRow.releaseTimestamp,'2020-01-01T00:00:00.000Z');
const releaseRow=releasesAdapter.transform({version:'v1.0.0',releaseTimestamp:'2026-01-01T00:00:00.000Z',isDraft:false,isPrerelease:false,url:'https://example.com',id:1,name:null,description:null});
assert.equal(releaseRow.releaseTimestamp,'2026-01-01T00:00:00.000Z');
rmdirSync(localDir);
console.log(JSON.stringify({renovate:renovateVersion,cases:results},null,2));
