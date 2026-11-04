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
for(const value of ['v1.0.0','1.0.0','v1.2.3-beta.1','v1.2.3+build.4']) {
 const c=await cfg(value); assert.equal(c.datasource,'github-releases'); assert.equal(c.versioning,'github-actions'); results.push({case:'exact-version match',value});
}
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
const tagRow=tagsAdapter.transform({version:'v1.0.0',target:{type:'Commit',oid:'1'.repeat(40),releaseTimestamp:'2020-01-01T00:00:00.000Z'}});
assert.equal(tagRow.releaseTimestamp,'2020-01-01T00:00:00.000Z');
const releaseRow=releasesAdapter.transform({version:'v1.0.0',releaseTimestamp:'2026-01-01T00:00:00.000Z',isDraft:false,isPrerelease:false,url:'https://example.com',id:1,name:null,description:null});
assert.equal(releaseRow.releaseTimestamp,'2026-01-01T00:00:00.000Z');
rmdirSync(localDir);
console.log(JSON.stringify({renovate:renovateVersion,cases:results},null,2));
