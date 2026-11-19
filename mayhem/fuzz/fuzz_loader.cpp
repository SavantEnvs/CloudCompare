// libFuzzer harness for one CloudCompare file loader (FileIOFilter::loadFile).
//
// Built once per format: FUZZ_FILTER_HEADER / FUZZ_FILTER_CLASS / FUZZ_EXT pick the
// loader (see mayhem/build.sh). Every loader takes a file name, so the input is written
// to <scratch>/input.<ext> and loaded the way upstream's own QtTest tests do
// (libs/qCC_io/test, plugins/core/IO/qCoreIO/test): no load dialog, no parent widget.
//
// Kept across inputs: the QApplication (offscreen platform) and the scratch directory
// path. The scratch file is rewritten for every input and each input loads into a fresh
// ccHObject container. Loader state an input can leave behind is reset per input:
//  - ccGlobalShiftManager's static last-shift buffer (s_lastInfoBuffer): Handle() and
//    BinFilter append to it, and a later Handle() reuses a stored shift and skips
//    BestShift(). Upstream exposes it only as GetLast() (a const& to the static), so it
//    is cleared through that reference before every load.
//  - FileIOFilter's session counter (ResetSesionCounter(), as qCC/ccViewer do).
// The other loader statics are reset by the loaders themselves (PlyFilter::loadFile
// resets its counters; s_maxTextureIndex is set before its callback is registered),
// the texture DB is reference-counted and emptied when the container is destroyed,
// and AsciiOpenDlg's saved context is only written by a user "Apply", which the dialog
// rejecter below never does. So one input's result depends only on that input.
//
// Some loaders open a modal QMessageBox/QDialog with a null parent on corrupt input
// (e.g. BinFilter.cpp, AsciiFilter.cpp, ShpFilter.cpp) regardless of the load
// parameters. Headless, exec() would wait forever for a click, so an application-wide
// event filter rejects any dialog as soon as it is shown: the same as a user pressing
// "Cancel"/closing it. It changes no loader code.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <unistd.h>

#include <QApplication>
#include <QDialog>
#include <QEvent>
#include <QMetaObject>
#include <QObject>
#include <QString>

#include <FileIOFilter.h>
#include <ccHObject.h>
#include <ccGlobalShiftManager.h>

#include FUZZ_FILTER_HEADER

namespace
{
class DialogRejecter : public QObject
{
  protected:
	bool eventFilter(QObject* watched, QEvent* event) override
	{
		if (event->type() == QEvent::Show)
		{
			if (auto* dlg = qobject_cast<QDialog*>(watched))
			{
				QMetaObject::invokeMethod(dlg, "reject", Qt::QueuedConnection);
			}
		}
		return QObject::eventFilter(watched, event);
	}
};

QApplication* g_app = nullptr;
std::string   g_path;
} // namespace

extern "C" int LLVMFuzzerInitialize(int* argc, char*** argv)
{
	setenv("QT_QPA_PLATFORM", "offscreen", 0);
	static int   qargc    = 1;
	static char  name[]   = "fuzz_cloudcompare";
	static char* qargv[]  = {name, nullptr};
	g_app = new QApplication(qargc, qargv);
	g_app->installEventFilter(new DialogRejecter);

	const char* tmp = getenv("TMPDIR");
	std::string dir = std::string(tmp && *tmp ? tmp : "/tmp") + "/ccfuzz-XXXXXX";
	if (!mkdtemp(&dir[0]))
	{
		perror("mkdtemp");
		abort();
	}
	g_path = dir + "/input." FUZZ_EXT;
	return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	FILE* f = fopen(g_path.c_str(), "wb");
	if (!f)
	{
		abort();
	}
	if (size)
		fwrite(data, 1, size, f);
	fclose(f);

	// reset per-input loader state (see the header comment)
	const_cast<std::vector<ccGlobalShiftManager::ShiftInfo>&>(ccGlobalShiftManager::GetLast()).clear();
	FileIOFilter::ResetSesionCounter();

	ccHObject                    container;
	FileIOFilter::LoadParameters params;
	params.alwaysDisplayLoadDialog = false;
	params.parentWidget            = nullptr;
	params.shiftHandlingMode       = ccGlobalShiftManager::NO_DIALOG_AUTO_SHIFT;
	params.sessionStart            = true;

	FUZZ_FILTER_CLASS filter;
	filter.loadFile(QString::fromStdString(g_path), container, params);
	return 0;
}
