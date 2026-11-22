import os
import tempfile
import unittest

from claudenotch import gitinfo


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class BranchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_branch_from_a_subfolder(self):
        write(os.path.join(self.root, "repo", ".git", "HEAD"), "ref: refs/heads/feature/notch\n")
        sub = os.path.join(self.root, "repo", "src", "deep")
        os.makedirs(sub)
        self.assertEqual(gitinfo.branch(sub), "feature/notch")

    def test_detached_head_shows_a_short_hash(self):
        write(os.path.join(self.root, ".git", "HEAD"), "0123456789abcdef0123456789abcdef01234567\n")
        self.assertEqual(gitinfo.branch(self.root), "0123456")

    def test_worktree_pointer_relative_and_absolute(self):
        real = os.path.join(self.root, "main", ".git", "worktrees", "wt")
        write(os.path.join(real, "HEAD"), "ref: refs/heads/wt-branch\n")
        wt = os.path.join(self.root, "wt")
        write(os.path.join(wt, ".git"), f"gitdir: {real}\n")
        self.assertEqual(gitinfo.branch(wt), "wt-branch")
        rel = os.path.join(self.root, "wt2")
        write(os.path.join(rel, ".git"), "gitdir: ../main/.git/worktrees/wt\n")
        self.assertEqual(gitinfo.branch(rel), "wt-branch")

    def test_no_repo_and_broken_repo(self):
        self.assertEqual(gitinfo.branch(""), "")
        empty = os.path.join(self.root, "nothing")
        os.makedirs(empty)
        self.assertEqual(gitinfo.branch(empty), "")
        broken = os.path.join(self.root, "broken")
        os.makedirs(os.path.join(broken, ".git"))
        self.assertEqual(gitinfo.branch(broken), "")


if __name__ == "__main__":
    unittest.main()
