#!/bin/sh
#
# Usage: git-ftp-test.sh
#
# You can define environment variables to choose the FTP server to test on.
#
# Example:
#     export GIT_FTP_ROOT='localhost/git-ftp-tests'
#     export GIT_FTP_USER='git-ftp-test'
#     export GIT_FTP_PASSWD='s3cr3t'
#     ./git-ftp-test.sh
#
# You can choose test cases as well:
#     export TEST_CASES='test_displays_usage test_prints_version'
#     ./git-ftp-test.sh
#
# Or you can write it in one line:
#     TEST_CASES='test_displays_usage' GIT_FTP_PASSWD='s3cr3t' ./git-ftp-test.sh

suite() {
	for testcase in ${TEST_CASES}; do
		suite_addTest "$testcase"
	done
}

oneTimeSetUp() {
	cd "$TESTDIR/../"

	GIT_FTP_CMD="$(pwd)/git-ftp"
	: ${GIT_FTP_USER=ftp}
	: ${GIT_FTP_PASSWD=}
	: ${GIT_FTP_HOST=localhost}
	: ${GIT_FTP_PORT=:21}
	: ${GIT_FTP_ROOT=}

	START=$(date +%s)
}

oneTimeTearDown() {
	END=$(date +%s)
	DIFF=$(( $END - $START ))
	echo "It took $DIFF seconds"
}

setUp() {
	if command -v mktemp > /dev/null 2>&1; then
		GIT_PROJECT_PATH="$(mktemp -d -t git-ftp-XXXX)"
	else
		GIT_PROJECT_PATH="git-ftp-test-repo-$(date | md5sum | cut -d ' ' -f1)"
		mkdir -p "$GIT_PROJECT_PATH"
	fi
	GIT_PROJECT_NAME="$(basename $GIT_PROJECT_PATH)"

	GIT_FTP_URL="ftp://$GIT_FTP_HOST$GIT_FTP_PORT/$GIT_FTP_ROOT/$GIT_PROJECT_NAME"

	[ -n "$GIT_FTP_USER" ] && CURL_ARGS=" -u $GIT_FTP_USER:$GIT_FTP_PASSWD"
	CURL="curl $CURL_ARGS"
	CURL_URL="$GIT_FTP_URL"

	[ -n "$GIT_FTP_USER" ] && GIT_FTP_USER_ARG="-u $GIT_FTP_USER"
	[ -n "$GIT_FTP_PASSWD" ] && GIT_FTP_PASSWD_ARG="-p $GIT_FTP_PASSWD"
	GIT_FTP="$GIT_FTP_CMD $GIT_FTP_USER_ARG $GIT_FTP_PASSWD_ARG $GIT_FTP_URL"

	cd $GIT_PROJECT_PATH

	# make some content
	for i in 1 2 3 4 5
	do
		echo "$i" >> ./"test $i.txt"
		mkdir -p "dir $i"
		echo "$i" >> "dir $i/test $i.txt"
	done;

	# git them
	git init > /dev/null 2>&1
	git add . > /dev/null 2>&1
	git commit -a -m "init" > /dev/null 2>&1
}

tearDown() {
	tmpfiles=$(ls .git-ftp*-tmp 2> /dev/null)
	assertEquals '' "$tmpfiles"
	rm -rf $GIT_PROJECT_PATH
	command -v lftp >/dev/null 2>&1 && {
		lftp -u $GIT_FTP_USER,$GIT_FTP_PASSWD $GIT_FTP_ROOT -e "set ftp:list-options -a; rm -rf '$GIT_PROJECT_NAME'; exit" > /dev/null 2>&1
	}
}

test_displays_usage() {
	usage=$($GIT_FTP_CMD 2>&1)
	assertEquals "git-ftp <action> [<options>] <url>" "$usage"
}

test_prints_version() {
	version=$($GIT_FTP_CMD 2>&1 --version)
	assertEquals = "git-ftp version 1.2.0-UNRELEASED"  "$version"
}

test_inits() {
	init=$($GIT_FTP init)
	assertEquals 0 $?
	assertTrue 'file does not exist' "remote_file_exists 'test 1.txt'"
	assertTrue 'file differs' "remote_file_equals 'test 1.txt'"
}

test_init_fails() {
	init=$($GIT_FTP_CMD -v -u wrong_user -p wrong_passwd $GIT_FTP_URL init 2>&1)
	assertEquals 5 $?
	error_count=$(echo "$init" | grep -F 'Access denied' | wc -l)
	assertEquals 1 $error_count
}

test_inits_and_pushes() {
	cd $GIT_PROJECT_PATH

	# this should pass
	init=$($GIT_FTP init)
	rtrn=$?
	assertEquals 0 $rtrn

	# this should fail
	init2=$($GIT_FTP init 2>&1)
	rtrn=$?
	assertEquals 2 $rtrn
	assertEquals "fatal: Commit found, use 'git ftp push' to sync. Exiting..." "$init2"

	# make some changes
	echo "1" >> "./test 1.txt"
	git commit -a -m "change" > /dev/null 2>&1

	# this should pass
	push=$($GIT_FTP push)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_pushes_and_fails() {
	cd $GIT_PROJECT_PATH
	push="$($GIT_FTP push 2>&1)"
	rtrn=$?
	assertEquals "fatal: Could not get last commit. Network down? Wrong URL? Use 'git ftp init' for the initial push., exiting..." "$push"
	assertEquals 5 $rtrn
}

test_push_unknown_commit() {
	$GIT_FTP init > /dev/null
	echo '000000000' | $CURL -s -T - $CURL_URL/.git-ftp.log
	push="$($GIT_FTP push 0>&- 2>&1)"
	assertEquals 0 $?
	assertContains 'Unknown SHA1 object' "$push"
	assertContains 'Do you want to ignore' "$push"
}

test_push_nothing() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	# make some changes
	echo "1" >> "./test 1.txt"
	git commit -a -m "change" > /dev/null 2>&1
	push=$($GIT_FTP push --dry-run)
	assertEquals 0 $?
	assertTrue "$push" "echo \"$push\" | grep '1 file to sync:'"
	echo 'test 1.txt' >> .git-ftp-ignore
	push=$($GIT_FTP push)
	assertEquals 0 $?
	firstline=$(echo "$push" | head -n 1)
	assertEquals 'There are no files to sync.' "$firstline"
}

test_push_added() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	# add a file
	file='newfile.txt'
	echo "1" > "./$file"
	git add $file
	git commit -m "change" > /dev/null 2>&1
	push=$($GIT_FTP push)
	assertEquals 0 $? || echo "Push: $push"
	assertEquals "1" "$($CURL -s $CURL_URL/$file)"
}

test_push_twice() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	# make some changes
	echo "1" >> "./test 1.txt"
	git commit -a -m "change" > /dev/null 2>&1
	push=$($GIT_FTP push)
	assertEquals 0 $? || echo "First push: $push"
	push=$($GIT_FTP push)
	assertEquals 0 $? || echo "Second push: $push"
	assertTrue "$push" "echo \"$push\" | grep 'Everything up-to-date.'"
}

test_push_unknown_sha1() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	# make some changes
	echo "1" >> "./test 1.txt"
	git commit -a -m "change" > /dev/null 2>&1
	# change remote SHA1
	echo '000000000' | $CURL -T - $CURL_URL/.git-ftp.log 2> /dev/null
	push=$(echo 'N' | $GIT_FTP push)
	assertEquals 0 $?
	echo "$push" | grep 'Unknown SHA1 object' > /dev/null
	assertFalse ' test 1.txt uploaded' "remote_file_equals 'test 1.txt'"
}

test_push_unknown_sha1_Y() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	# make some changes
	echo "1" >> "./test 1.txt"
	git commit -a -m "change" > /dev/null 2>&1
	# change remote SHA1
	echo '000000000' | $CURL -T - $CURL_URL/.git-ftp.log 2> /dev/null
	push=$(echo 'Y' | $GIT_FTP push)
	assertEquals 0 $?
	echo "$push" | grep 'Unknown SHA1 object' > /dev/null
	assertEquals 0 $?
	assertTrue ' test 1.txt uploaded' "remote_file_equals 'test 1.txt'"
}

test_defaults() {
	cd $GIT_PROJECT_PATH
	git config git-ftp.user $GIT_FTP_USER
	git config git-ftp.password $GIT_FTP_PASSWD
	git config git-ftp.url $GIT_FTP_URL

	init=$($GIT_FTP_CMD init)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_defaults_uses_url_by_cli() {
	cd $GIT_PROJECT_PATH
	git config git-ftp.user $GIT_FTP_USER
	git config git-ftp.password $GIT_FTP_PASSWD
	git config git-ftp.url notexisits

	init=$($GIT_FTP_CMD init $GIT_FTP_URL)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_defaults_uses_user_by_cli() {
	[ -z "$GIT_FTP_USER" ] && startSkipping
	cd $GIT_PROJECT_PATH
	git config git-ftp.user johndoe
	git config git-ftp.password $GIT_FTP_PASSWD
	git config git-ftp.url $GIT_FTP_URL

	init=$($GIT_FTP_CMD init $GIT_FTP_USER_ARG)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_defaults_uses_password_by_cli() {
	[ -z "$GIT_FTP_PASSWD" ] && startSkipping
	cd $GIT_PROJECT_PATH
	git config git-ftp.user $GIT_FTP_USER
	git config git-ftp.password wrongpasswd
	git config git-ftp.url $GIT_FTP_URL

	init=$($GIT_FTP_CMD init $GIT_FTP_PASSWD_ARG)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_deployedsha1file_rename() {
	local file='git-ftp.txt'
	git config git-ftp.deployedsha1file "$file"
	init=$($GIT_FTP init)
	assertEquals 0 $?
	assertTrue " '$file' does not exist" "remote_file_exists '$file'"
	assertFalse " '.git-ftp.log' does exist" "remote_file_exists '.git-ftp.log'"
}

test_scopes() {
	cd $GIT_PROJECT_PATH
	git config git-ftp.user $GIT_FTP_USER
	git config git-ftp.password wrongpasswd
	git config git-ftp.url $GIT_FTP_URL

	git config git-ftp.testing.password $GIT_FTP_PASSWD

	init=$($GIT_FTP_CMD init -s testing)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_invalid_scope_name() {
	out=$($GIT_FTP_CMD init -s invalid:scope 2>&1)
	assertEquals 2 $?
	assertEquals 'fatal: Invalid scope name.' "$out"

	out=$($GIT_FTP_CMD add-scope invalid:scope 2>&1)
	assertEquals 2 $?
	assertEquals 'fatal: Invalid scope name.' "$out"
}

test_scopes_using_branchname_as_scope() {
	cd $GIT_PROJECT_PATH
	git config git-ftp.production.user $GIT_FTP_USER
	git config git-ftp.production.password $GIT_FTP_PASSWD
	git config git-ftp.production.url $GIT_FTP_URL
	git checkout -b production > /dev/null 2>&1

	init=$($GIT_FTP_CMD init -s)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_overwrite_defaults_by_scopes_emtpy_string() {
	cd $GIT_PROJECT_PATH
	git config git-ftp.user $GIT_FTP_USER
	git config git-ftp.password $GIT_FTP_PASSWD
	git config git-ftp.url $GIT_FTP_URL

	git config git-ftp.testing.url ''

	init=$($GIT_FTP_CMD init -s testing 2>/dev/null)
	rtrn=$?
	assertEquals 3 $rtrn
}

test_scopes_uses_password_by_cli() {
	cd $GIT_PROJECT_PATH
	git config git-ftp.user $GIT_FTP_USER
	git config git-ftp.password wrongpasswd
	git config git-ftp.url $GIT_FTP_URL

	git config git-ftp.testing.password wrongpasswdtoo

	init=$($GIT_FTP_CMD init -s testing $GIT_FTP_PASSWD_ARG)
	rtrn=$?
	assertEquals 0 $rtrn
}

test_scopes_add() {
	add=$($GIT_FTP_CMD add-scope xyz ftpes://user:password@ftp.example.com/xyz)
	assertEquals 0 $?
	assertFalse 'Does not display warning with valid URL' "echo $add | grep ^Warning -q"
	add=$($GIT_FTP_CMD add-scope xyz ftpes://user:pass:word@ftp.example.com/xyz)
	assertEquals 0 $?
	assertTrue 'Does display warning invalid URL' "echo $add | grep ^Warning -q"
}

test_delete() {
	cd $GIT_PROJECT_PATH

	init=$($GIT_FTP init)

	assertTrue 'test failed: file does not exist' "remote_file_exists 'test 1.txt'"

	git rm "test 1.txt" > /dev/null 2>&1
	git commit -a -m "delete file" > /dev/null 2>&1

	push=$($GIT_FTP push)
	rtrn=$?
	assertEquals 0 $rtrn

	assertFalse 'test failed: file still exists' "remote_file_exists 'test 1.txt'"
	assertTrue 'test failed: file does not exist' "remote_file_exists 'dir 1/test 1.txt'"

	git rm -r "dir 1" > /dev/null 2>&1
	git commit -a -m "delete dir" > /dev/null 2>&1

	push=$($GIT_FTP push)

	assertFalse 'test failed: dir and file still exists' "remote_file_exists 'dir 1/test 1.txt'"
# See https://github.com/git-ftp/git-ftp/issues/168
#	assertFalse 'test failed: dir still exists' "remote_file_exists 'dir 1/'"
}

test_ignore_single_file() {
	cd $GIT_PROJECT_PATH
	echo "test 1.txt" > .git-ftp-ignore

	init=$($GIT_FTP init)

	assertFalse 'test failed: file was not ignored' "remote_file_exists 'test 1.txt'"
}

test_ignore_single_file_force_unknown_commit() {
	init=$($GIT_FTP init)
	local file='ignored.txt'
	touch $file
	echo $file > .git-ftp-ignore
	git add .
	git commit -m 'added new file that should be ignored' -q
	echo '000000000' | $CURL -s -T - $CURL_URL/.git-ftp.log
	push=$($GIT_FTP push -f)
	assertFalse 'test failed: file was not ignored' "remote_file_exists '$file'"
}

test_ignore_dir() {
	cd $GIT_PROJECT_PATH
	echo "dir 1/*" > .git-ftp-ignore

	init=$($GIT_FTP init)

	assertFalse 'test failed: dir was not ignored' "remote_file_exists 'dir 1/test 1.txt'"
	assertTrue 'test failed: wrong dir was ignored' "remote_file_exists 'dir 2/test 2.txt'"
}

test_ignore_pattern() {
	cd $GIT_PROJECT_PATH
	echo "test*" > .git-ftp-ignore

	init=$($GIT_FTP init)

	for i in 1 2 3 4 5
	do
		assertFalse 'test failed: was not ignored' "remote_file_exists 'test $i.txt'"
	done;
}

test_ignore_pattern_single() {
	cd $GIT_PROJECT_PATH
	echo 'test' > 'test'
	echo 'test' > .git-ftp-ignore
	git add .
	git commit -m 'adding file that should not be uploaded' > /dev/null

	init=$($GIT_FTP init)

	assertFalse 'test failed: was not ignored' "remote_file_exists 'test'"
	for i in 1 2 3 4 5
	do
		assertTrue 'test failed: was ignored' "remote_file_exists 'test $i.txt'"
	done;
}

test_ignore_wildcard_files() {
	cd $GIT_PROJECT_PATH
	echo "test *.txt" > .git-ftp-ignore

	init=$($GIT_FTP init)

	for i in 1 2 3 4 5
	do
		assertFalse 'test failed: was not ignored' "remote_file_exists 'test $i.txt'"
	done;
}

test_include_init() {
	cd $GIT_PROJECT_PATH
	echo 'unversioned' > unversioned.txt
	echo 'unversioned.txt' >> .gitignore
	echo 'unversioned.txt:test 1.txt' > .git-ftp-include
	echo 'new content' >> 'test 1.txt'
	git add .
	git commit -m 'unversioned file unversioned.txt should be uploaded with test 1.txt' > /dev/null
	init=$($GIT_FTP init)
	assertTrue 'unversioned.txt was not uploaded' "remote_file_exists 'unversioned.txt'"
}

test_include_directory() {
	mkdir unversioned
	touch unversioned/file.txt
	echo 'unversioned/:test 1.txt' > .git-ftp-include
	mkdir unversioned-not-included
	touch unversioned-not-included/file.txt
	init=$($GIT_FTP init)
	assertTrue 'unversioned/file.txt was not uploaded' "remote_file_exists 'unversioned/file.txt'"
	assertFalse 'unversioned-not-included/file.txt was uploaded' "remote_file_exists 'unversioned-not-included/file.txt'"
}

test_include_directory_always() {
	mkdir unversioned
	touch unversioned/file.txt
	echo '!unversioned/' > .git-ftp-include
	mkdir unversioned-not-included
	touch unversioned-not-included/file.txt
	init=$($GIT_FTP init)
	assertTrue 'unversioned/file.txt was not uploaded' "remote_file_exists 'unversioned/file.txt'"
	assertFalse 'unversioned-not-included/file.txt was uploaded' "remote_file_exists 'unversioned-not-included/file.txt'"
}

test_include_whitespace_init() {
	cd $GIT_PROJECT_PATH
	echo 'unversioned' > unversioned.txt
	echo 'unversioned.txt' >> .gitignore
	echo 'unversioned.txt:test X.txt' > .git-ftp-include
	git add .
	git commit -m 'unversioned file unversioned.txt should not be uploaded. test X.txt does not exist.' > /dev/null
	init=$($GIT_FTP init)
	assertFalse 'unversioned.txt was uploaded' "remote_file_exists 'unversioned.txt'"
}

test_include_push() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	echo 'unversioned' > unversioned.txt
	echo 'unversioned.txt' >> .gitignore
	echo 'unversioned.txt:test 1.txt' > .git-ftp-include
	echo 'new content' >> 'test 1.txt'
	git add .
	git commit -m 'unversioned file unversioned.txt should be uploaded with test 1.txt' > /dev/null
	push=$($GIT_FTP push)
	assertTrue 'unversioned.txt was not uploaded' "remote_file_exists 'unversioned.txt'"
}

test_include_push_delete() {
	echo 'unversioned' > unversioned.txt
	echo 'unversioned.txt' >> .gitignore
	echo 'unversioned.txt:test 1.txt' > .git-ftp-include
	echo 'unversioned.txt:test 2.txt' >> .git-ftp-include
	echo 'new content' >> 'test 1.txt'
	git add .
	git commit -m 'unversioned file unversioned.txt should be uploaded with test 1.txt' -q
	init=$($GIT_FTP init)
	git rm 'test 1.txt' -q
	git commit -m 'the trigger file of unversioned.txt is deleted which deletes the target file' -q
	push=$($GIT_FTP push)
	assertTrue 'unversioned.txt was deleted' "remote_file_exists 'unversioned.txt'"
	echo 'new content' >> 'test 2.txt'
	rm 'unversioned.txt'
	git commit -a -m 'the local deletion of unversioned.txt should delete remote file' -q
	push=$($GIT_FTP push)
	assertFalse 'unversioned.txt was not deleted' "remote_file_exists 'unversioned.txt'"
}

test_include_ignore_init() {
	cd $GIT_PROJECT_PATH
	echo 'htaccess' > .htaccess
	echo 'htaccess.prod' > .htaccess.prod
	echo '.htaccess:.htaccess.prod' > .git-ftp-include
	echo '.htaccess.prod' > .gitignore
	git add .
	git commit -m 'htaccess setup' > /dev/null
	init=$($GIT_FTP init)
	assertTrue ' .htaccess was ignored' "remote_file_exists '.htaccess'"
	assertFalse ' .htaccess.prod was uploaded' "remote_file_exists '.htaccess.prod'"
}

test_include_ignore_push() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	echo 'htaccess' > .htaccess
	echo 'htaccess.prod' > .htaccess.prod
	echo '.htaccess:.htaccess.prod' > .git-ftp-include
	echo '.htaccess.prod' > .gitignore
	git add .
	git commit -m 'htaccess setup' > /dev/null
	push=$($GIT_FTP push)
	assertTrue ' .htaccess was ignored' "remote_file_exists '.htaccess'"
	assertFalse ' .htaccess.prod was uploaded' "remote_file_exists '.htaccess.prod'"
}

test_include_ftp_ignore_init() {
	cd $GIT_PROJECT_PATH
	echo 'htaccess' > .htaccess
	echo 'htaccess.prod' > .htaccess.prod
	echo '.htaccess:.htaccess.prod' > .git-ftp-include
	echo '.htaccess.prod' > .git-ftp-ignore
	git add .
	git commit -m 'htaccess setup' > /dev/null
	init=$($GIT_FTP init)
	assertTrue ' .htaccess was ignored' "remote_file_exists '.htaccess'"
	assertFalse ' .htaccess.prod was uploaded' "remote_file_exists '.htaccess.prod'"
}

test_include_ftp_ignore_push() {
	cd $GIT_PROJECT_PATH
	init=$($GIT_FTP init)
	echo 'htaccess' > .htaccess
	echo 'htaccess.prod' > .htaccess.prod
	echo '.htaccess:.htaccess.prod' > .git-ftp-include
	echo '.htaccess.prod' > .git-ftp-ignore
	git add .
	git commit -m 'htaccess setup' > /dev/null
	push=$($GIT_FTP push)
	assertTrue ' .htaccess was ignored' "remote_file_exists '.htaccess'"
	assertFalse ' .htaccess.prod was uploaded' "remote_file_exists '.htaccess.prod'"
}

# addresses issue #41
test_include_similar() {
	cd $GIT_PROJECT_PATH
	echo 'unversioned' > foo.html
	echo '/foo.html' >> .gitignore
	echo 'foo.html:templates/foo.html' > .git-ftp-include
	mkdir templates
	echo 'new content' >> 'templates/foo.html'
	git add .
	git commit -m 'unversioned file foo.html should be uploaded with templates/foo.html' > /dev/null
	init=$($GIT_FTP init)
	assertTrue 'foo.html was not uploaded' "remote_file_exists 'foo.html'"
	assertTrue 'templates/foo.html was not uploaded' "remote_file_exists 'templates/foo.html'"
}

test_hidden_file_only() {
	cd $GIT_PROJECT_PATH
	echo "test" > .htaccess
	git add . > /dev/null 2>&1
	git commit -a -m "init" > /dev/null 2>&1
	init=$($GIT_FTP init)
	assertTrue 'test failed: .htaccess not uploaded' "remote_file_exists '.htaccess'"
}


# issue #23
test_file_with_nonchar() {
	file1='#4253-Release Contest.md'
	file1enc='%234253-Release%20Contest.md'
	file2='v1.2.0 #8950 - Custom Partner Player.md'
	file2enc='v1.2.0%20%238950%20-%20Custom%20Partner%20Player.md'
	echo 'content1' > "$file1"
	echo 'content2' > "$file2"
	git add .
	git commit -a -m 'added special filenames' -q
	init=$($GIT_FTP init)
	assertTrue " file $file1 not uploaded" "remote_file_equals '$file1' '$file1enc'"
	assertTrue " file $file2 not uploaded" "remote_file_equals '$file2' '$file2enc'"
	git rm "$file1" -q
	git rm "$file2" -q
	git commit -m 'delete' -q
	push=$($GIT_FTP push)
	assertFalse "file $file1 still exists in $CURL_URL" "remote_file_exists '$file1enc'"
	assertFalse "file $file2 still exists in $CURL_URL" "remote_file_exists '$file2enc'"
}

# issue #209
test_file_with_unicode() {
	supports_unicode || startSkipping
	file1='umlaut_ä.md'
	file1enc='umlaut_%C3%A4.md'
	echo 'content' > "$file1"
	git add .
	git commit -a -m 'added special filenames' -q
	init=$($GIT_FTP init)
	assertTrue " file $file1 not uploaded" "remote_file_equals '$file1' '$file1enc'"
	git rm "$file1" -q
	git commit -m 'delete' -q
	push=$($GIT_FTP push)
	assertFalse "file $file1 still exists in $CURL_URL" "remote_file_exists '$file1enc'"
}

test_syncroot() {
	cd $GIT_PROJECT_PATH
	syncroot='foo bar'
	mkdir "$syncroot" && echo "test" > "$syncroot/syncroot.txt"
	git add . > /dev/null 2>&1
	git commit -a -m "syncroot test" > /dev/null 2>&1
	init=$($GIT_FTP init --syncroot "$syncroot")
	assertTrue 'test failed: syncroot.txt not there as expected' "remote_file_exists 'syncroot.txt'"
}

test_download() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' > external.txt
	$CURL -T external.txt $CURL_URL/ 2> /dev/null
	rtrn=$?
	assertEquals 0 $rtrn
	rm external.txt
	$GIT_FTP download > /dev/null 2>&1
	rtrn=$?
	assertEquals 0 $rtrn
	assertTrue ' external file not downloaded' "[ -r 'external.txt' ]"
}

test_download_untracked() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' | $CURL -T - $CURL_URL/external.txt 2> /dev/null
	touch 'untracked.file'
	$GIT_FTP download > /dev/null 2>&1
	assertEquals 8 $?
	assertFalse ' external file downloaded' "[ -f 'external.txt' ]"
	assertTrue ' untracked file deleted' "[ -r 'untracked.file' ]"
}

test_download_syncroot() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	mkdir foobar && echo "test" > foobar/syncroot.txt
	git add . > /dev/null 2>&1
	git commit -a -m "syncroot test" > /dev/null 2>&1
	init=$($GIT_FTP init --syncroot foobar)
	echo 'foreign content' > external.txt
	$CURL -T external.txt $CURL_URL/ 2> /dev/null
	rm external.txt
	$GIT_FTP download --syncroot foobar/ > /dev/null 2>&1
	rtrn=$?
	assertEquals 0 $rtrn
	assertFalse ' external file downloaded to git root' "[ -r 'external.txt' ]"
	assertTrue ' external file not downloaded to syncroot' "[ -r 'foobar/external.txt' ]"
}

test_download_dry_run() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' | $CURL -T - $CURL_URL/external.txt 2> /dev/null
	$GIT_FTP download --dry-run > /dev/null 2>&1
	assertEquals 0 $?
	assertTrue ' external file downloaded' "[ ! -e 'external.txt' ]"
}

test_pull() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' > external.txt
	$CURL -T external.txt $CURL_URL/ 2> /dev/null
	rm external.txt
	echo 'own content' > internal.txt
	git add . > /dev/null 2>&1
	git commit -a -m "local modification" > /dev/null 2>&1
	$GIT_FTP pull > /dev/null 2>&1
	rtrn=$?
	assertEquals 0 $rtrn
	assertTrue ' external file not downloaded' "[ -r 'external.txt' ]"
}

test_pull_nothing() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	$GIT_FTP pull > /dev/null 2>&1
	assertEquals 0 $?
}

test_pull_branch() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' > external.txt
	$CURL -T external.txt $CURL_URL/ 2> /dev/null
	rm external.txt
	echo 'own content' > internal.txt
	git add . > /dev/null 2>&1
	git commit -a -m "local modification" > /dev/null 2>&1
	git checkout -b deploy-branch > /dev/null 2>&1
	echo '1' > version.txt
	git add -A .
	git commit -m 'branch modification' > /dev/null 2>&1
	$GIT_FTP pull > /dev/null 2>&1
	rtrn=$?
	assertEquals 0 $rtrn
	assertTrue ' external file not downloaded' "[ -r 'external.txt' ]"
	assertTrue ' version.txt of deploy-branch not found' "[ -r 'version.txt' ]"
	assertEquals '## deploy-branch' "$(git status -sb)"
}

test_pull_no_commit() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' > external.txt
	$CURL -T external.txt $CURL_URL/ 2> /dev/null
	rm external.txt
	echo 'own content' > internal.txt
	git add . > /dev/null 2>&1
	git commit -a -m "local modification" > /dev/null 2>&1
	LOCAL_SHA1=$(git log -n 1 --pretty=format:%H)
	$GIT_FTP pull --no-commit > /dev/null 2>&1
	rtrn=$?
	assertEquals 0 $rtrn
	assertTrue ' external file not downloaded' "[ -r 'external.txt' ]"
	assertEquals $LOCAL_SHA1 $(git log -n 1 --pretty=format:%H)
}

test_pull_dry_run() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' | $CURL -T - $CURL_URL/external.txt 2> /dev/null
	echo 'own content' > internal.txt
	git add . > /dev/null 2>&1
	git commit -a -m "local modification" > /dev/null 2>&1
	pull=$($GIT_FTP pull --dry-run 2> /dev/null)
	assertEquals 0 $?
	assertTrue ' external file downloaded' "[ ! -e 'external.txt' ]"
	assertFalse "$pull" "echo \"$pull\" | grep 'Last deployment changed to '"
	# TODO: idea: really download files and show `git diff` and `git diff --stat`, then reset
}

test_pull_untracked() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' | $CURL -T - $CURL_URL/external.txt 2> /dev/null
	echo 'own content' > internal.txt
	echo 'internal.txt' >> .gitignore
	git add . > /dev/null 2>&1
	git commit -a -m "ignore some file" > /dev/null 2>&1
	pull=$($GIT_FTP pull 2> /dev/null)
	assertEquals 0 $?
	assertTrue 'internal.txt is missing' "[ -f internal.txt ]"
	assertEquals '' "$(git log -- 'internal.txt')"
}

test_pull_stash() {
	skip_without lftp
	cd $GIT_PROJECT_PATH
	$GIT_FTP init > /dev/null
	echo 'foreign content' | $CURL -T - $CURL_URL/external.txt 2> /dev/null
	echo 'own content' > internal.txt
	git stash -u -q
	pull=$($GIT_FTP pull 2> /dev/null)
	assertEquals 0 $?
	stash_count="$(git stash list | wc -l)"
	stash_count=$((stash_count+0)) # trims whitespaces produced by wc on OSX
	assertEquals 1 "$stash_count"
	assertFalse 'internal.txt appeared' "[ -f internal.txt ]"
	assertEquals '' "$(git log -- 'internal.txt')"
}

test_submodule() {
	submodule='sub'
	file='file.txt'
	mkdir "$submodule"
	cd "$submodule"
	touch "$file"
	git init -q
	git add .
	git commit -m 'initial submodule commit' -q
	cd ..
	git submodule -q add "/$submodule" > /dev/null
	git commit -m 'adding submodule' -q
	init=$($GIT_FTP init)
	assertTrue "test failed: $file not there as expected" "remote_file_exists '$submodule/$file'"
}

test_submodule_catchup() {
	submodule='sub'
	file='file.txt'
	mkdir "$submodule"
	cd "$submodule"
	touch "$file"
	git init -q
	git add .
	git commit -m 'initial submodule commit' -q
	cd ..
	git submodule -q add "/$submodule" > /dev/null
	git commit -m 'adding submodule' -q
	catchup=$($GIT_FTP catchup)
	assertTrue "test failed: $submodule/.git-ftp.log not there as expected" "remote_file_exists '$submodule/.git-ftp.log'"
}

disabled_test_file_named_dash() {
	cd $GIT_PROJECT_PATH
	echo "foobar" > -
	assertTrue 'test failed: file named - not there as expected' "[ -f '$GIT_PROJECT_PATH/-' ]"
	git add . > /dev/null 2>&1
	git commit -a -m "file named - test" > /dev/null 2>&1
	init=$($GIT_FTP init)
	rtrn=$?
	assertEquals 0 $rtrn
}

remote_file_exists() {
	$CURL "$CURL_URL/$1" --head > /dev/null
}

remote_file_equals() {
	local file="$1"
	local remote="$2"
	[ -z "$remote" ] && remote="$file"
	$CURL -s "$CURL_URL/$remote" | diff - "$file" > /dev/null
}

assertContains() {
	assertTrue "Could not find expression: $1\nTested: $2" "echo \"$2\" | grep '$1'"
}

skip_without() {
	command -v $1 > /dev/null || startSkipping
}

supports_unicode() {
	count="$(printf 'a\nä\n' | sort -u | wc -l)"
	count=$((count+0)) # trims whitespaces produced by wc on OSX
	test "$count" = "2"
}

# load and run shUnit2
TESTDIR=$(dirname $0)
. $TESTDIR/shunit2-2.1.6/src/shunit2
