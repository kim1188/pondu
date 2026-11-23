# design/pondu.flow.json 을 만든 스크립트. 저장소 루트에서: python3 design/make-flow.py
# 그 뒤 README.md 의 명령으로 검사하고 HTML을 다시 만든다. JSON을 직접 고쳐도 되지만, 그러면 이 파일과 어긋난다.
import json
A=lambda id,label,to,**k: {"id":id,"label":label,"to":to,**k}
tabs=lambda cur: [A(f"tab-{t}",l,t,kind="tab") for t,l in (("today","오늘"),("together","함께"),("record","기록")) if t!=cur]
S=[]
def scr(id,number,title,stage,origin,brief,actions,**k): S.append({"id":id,"number":number,"title":title,"stage":stage,"origin":origin,"brief":brief,"actions":actions,**k})
rows=lambda *r: {"type":"rows","rows":[{"label":a,"value":b} for a,b in r]}

# ── 0 가입
scr("email","01.01","학교 메일 입력",0,"source","고려대 메일(@korea.ac.kr)로만 가입한다. 메일로 6자리 코드를 보낸다.",
  [A("send-code","코드 받기","code",validate=True), A("wrong-domain","다른 학교·일반 메일을 넣음","email-error",kind="simulation")],
  ui={"heading":"학교 메일로 시작해요","blocks":[{"type":"input","label":"학교 메일","field":"email","inputType":"email","required":True},{"type":"text","label":"@korea.ac.kr 메일만 쓸 수 있어요."}]},
  uxConditions=["도메인 검사는 서버가 한다. 앱에서 막아도 서버가 다시 거절한다.","메일 주소는 다른 사용자에게 보이지 않는다."])
scr("email-error","01.02","학교 메일이 아님",0,"source","학교 메일이 아니면 가입할 수 없다고 알리고 다시 입력하게 한다.",
  [A("retry-email","메일 다시 입력","email")],tone="error",body="고려대 메일(@korea.ac.kr)만 가입할 수 있어요.",preview={"email":"me@gmail.com"},
  ui={"blocks":[rows(("입력한 메일","{{email}}"))]})
scr("code","01.03","6자리 코드 입력",0,"source","메일로 받은 6자리 코드를 입력해 로그인한다.",
  [A("verify","확인","profile",validate=True),A("back-email","메일 다시 입력","email",kind="back"),A("resend","코드 다시 받기","code",kind="secondary",inc={"resent":1})],
  ui={"heading":"메일로 보낸 코드를 입력해요","blocks":[rows(("보낸 곳","{{email}}"),("다시 보낸 횟수","{{resent}}회")),{"type":"input","label":"6자리 코드","field":"otp","required":True}]},
  uxConditions=["코드가 틀리거나 만료되면 같은 화면에서 안내하고 다시 받게 한다(더미에서는 생략)."])
scr("profile","01.04","프로필 만들기",0,"source","이름과 학과를 정한다. 학과는 공식 목록 65개에서 고른다.",
  [A("save-profile","다음","calendar",validate=True)],
  ui={"heading":"어떻게 불러 드릴까요?","blocks":[{"type":"input","label":"이름","field":"name","required":True},{"type":"select","label":"학과","field":"major","options":["인공지능학과","컴퓨터학과","데이터과학과","경영학과"]}]})
scr("calendar","01.05","캘린더 읽기 허용",0,"source","iPhone 캘린더 권한을 요청하고 읽을 캘린더를 고른다. 일정 제목은 기기 밖으로 나가지 않는다.",
  [A("allow-cal","캘린더 연결","today",set={"calendar":"연결됨"}),A("skip-cal","나중에","today",kind="secondary")],
  body="수업과 약속 시간을 피해 계획을 잡아요. 비서에게는 바쁜 시간의 시작과 끝만 보내요.",
  uxConditions=["허용하지 않아도 앱을 쓸 수 있다. 그때는 바쁜 시간 없이 계획한다."])

# ── 1 오늘
scr("today","02.01","오늘",1,"source","오늘의 고정 일정, 지금 시작할 수 있는 일, 남은 할 일, 비서 진입점을 한 화면에 둔다.",
  [A("start-now","지금 시작 · DB 과제","session-start",set={"sessionTitle":"DB 과제","together":"혼자"}),
   A("plan-day","하루 정리","consent",kind="inline"),A("reschedule","남은 일 조정","reschedule",kind="inline"),
   A("capture","한 줄 입력","capture",kind="inline"),A("import","가져오기","import",kind="inline"),
   A("free-start","할 일 없이 바로 시작","session-start",kind="secondary",set={"sessionTitle":"자유 기록","together":"혼자"}),
   A("no-todos","할 일이 하나도 없음","today-empty",kind="simulation")]+tabs("today"),
  ui={"bar":"오늘","blocks":[rows(("10:30~12:00","자료구조 (캘린더)"),("지금 할 수 있는 일","DB 과제 · 60분"),("남은 할 일","영어 단어 · 앱 로그인 수정"),("캘린더","{{calendar}}"))]},
  uxConditions=["알림을 받았거나 예정 시각이 돼도 세션이 저절로 시작되지 않는다.","친구가 없어도 오늘과 기록만으로 쓸 수 있어야 한다."])
scr("today-empty","02.02","오늘 · 할 일 없음",1,"inferred","할 일이 없어도 기록을 시작하거나 할 일을 넣을 길을 보여 준다.",
  [A("free-start-empty","바로 시작","session-start",set={"sessionTitle":"자유 기록","together":"혼자"}),A("capture-empty","할 일 적기","capture",kind="secondary"),A("import-empty","가져오기","import",kind="secondary")],
  body="아직 할 일이 없어요. 바로 기록을 시작하거나 할 일을 적어 보세요.")
scr("import","02.03","가져오기 · 붙여 넣기",1,"source","투두 앱이나 시간표의 글을 붙여 넣으면 후보 항목을 뽑는다.",
  [A("extract","항목 찾기","import-review",validate=True),A("back-import","오늘","today",kind="back")],
  ui={"blocks":[{"type":"input","label":"붙여 넣은 글","field":"pasted","inputType":"textarea","required":True}]})
scr("import-review","02.04","가져오기 · 확인",1,"source","뽑은 후보를 보여 주고 애매한 항목을 표시한다. 확인한 것만 저장한다.",
  [A("save-import","고른 것만 저장","today"),A("back-review","다시 붙여 넣기","import",kind="back")],
  ui={"blocks":[rows(("선형대수 과제","금요일까지"),("알고리즘 복습","기한 없음"),("스터디 (애매함)","날짜를 확인해 주세요")),{"type":"notice","label":"애매한 항목은 꺼 둔 채로 보여 줘요."}]})

# ── 2 비서
scr("consent","03.01","비서 사용 동의",2,"source","첫 사용 전에 무엇이 서버와 AI로 가는지 알리고 동의를 받는다.",
  [A("agree","동의하고 시작","plan-input",set={"consented":True}),A("decline","취소","today",kind="secondary")],
  ui={"heading":"비서를 쓰기 전에","blocks":[rows(("보내는 것","입력한 문장"),("보내는 것","열린 할 일의 제목"),("보내는 것","바쁜 시간의 시작과 끝")),{"type":"notice","label":"캘린더 일정의 제목과 메모는 기기 밖으로 나가지 않아요."}]},
  uxConditions=["한 번 동의하면 다시 묻지 않는다(더미에서는 매번 보인다)."])
scr("plan-input","03.02","하루 정리 · 입력",2,"source","오늘 하고 싶은 일을 문장으로 적으면 비서가 바쁜 시간을 피해 초안을 만든다.",
  [A("ask","비서에게 보내기","proposal",set={"ask":"묻는 중","est":"30분","fit":"미정"}),A("fail","비서 응답 실패(20초 초과)","assistant-failed",kind="simulation"),A("close-plan","닫기","today",kind="back")],
  ui={"blocks":[{"type":"input","label":"오늘 하고 싶은 일(선택)","field":"planText","inputType":"textarea"},{"type":"notice","label":"비서가 만든 것은 초안이에요. 적용하기 전에는 아무것도 저장되지 않아요."}]})
scr("proposal","03.03","비서 초안",2,"source","초안을 보여 주고 전부 또는 일부만 적용하게 한다. 예상 시간이 없는 일은 30분으로 잡고 2분 동안 묻는다. 다 들어가지 않는 일은 가용 시간과 선택지를 보여 준다.",
  [A("apply","전부 적용","applied",kind="primary"),
   A("est-60","영어 단어 · 1시간 걸려요","proposal",kind="inline",when={"ask":"묻는 중"},set={"est":"60분","ask":"답함"}),
   A("est-skip","영어 단어 · 건너뛰기","proposal",kind="inline",when={"ask":"묻는 중"},set={"ask":"건너뜀"}),
   A("est-timeout","2분 동안 답이 없음","proposal",kind="simulation",when={"ask":"묻는 중"},set={"ask":"시간 지남"}),
   A("fit-partial","DB 과제 · 오늘 21:30~23:00에 1시간 30분만","proposal",kind="inline",when={"fit":"미정"},set={"fit":"오늘 1시간 30분만"}),
   A("fit-later","DB 과제 · 11월 24일 08:00~11:00로 옮기기","proposal",kind="inline",when={"fit":"미정"},set={"fit":"내일 08:00로 옮김"}),
   A("fit-skip","DB 과제 · 이번엔 건너뛰기","proposal",kind="inline",when={"fit":"미정"},set={"fit":"건너뜀"}),
   A("discard","적용하지 않고 닫기","today",kind="secondary")],
  preview={"ask":"묻는 중","est":"30분","fit":"미정"},
  ui={"bar":"하루 정리","blocks":[
    {"type":"text","label":"오늘은 세 가지를 잡아 봤어요."},
    rows(("15:00~16:00","앱 로그인 수정 · 60분"),("21:00~","영어 단어 · {{est}}"),("예상 시간 묻기","{{ask}}")),
    {"type":"notice","label":"‘영어 단어’ 얼마나 걸릴까요? 일단 30분으로 잡아 뒀어요. 2분 안에 답이 없으면 그대로 둘게요."},
    rows(("시간을 못 잡았어요","DB 과제 · 3시간 필요"),("오늘 한 번에 쓸 수 있는 시간","1시간 30분"),("오늘 남은 빈 시간","모두 1시간 30분"),("DB 과제를 어떻게 할까요","{{fit}}"))]},
  uxConditions=["예상 시간이 없는 일: 30분으로 먼저 잡는다. 답하면 그 길이로 바꾸고, 건너뛰거나 2분이 지나면 30분 그대로 둔다.",
    "답한 길이가 들어갈 자리가 없으면 그 일은 ‘시간을 못 잡았어요’로 옮겨 간다.",
    "한 가지 일은 통째로 잡는다. 다 들어가지 않으면 가용 시간을 보여 주고 일부만·다른 날·건너뛰기 중에 고르게 한다.",
    "묻는 중에 앱을 떠나면 알림이 한 번 간다. 답은 앱 안에서 고른다.",
    "비서는 말하지 않은 마감이나 목표를 만들지 않는다."])
scr("applied","03.04","적용 완료",2,"source","적용한 계획이 오늘 화면에 들어가고 예정 시각에 로컬 알림이 잡힌다.",
  [A("done-applied","닫기","today")],tone="success",end=True,body="적용했어요. 영어 단어 {{est}}, DB 과제는 ‘{{fit}}’.",preview={"est":"30분","fit":"미정"})
scr("assistant-failed","03.05","비서 실패 · 직접 입력",2,"source","비서가 실패하거나 늦으면 직접 입력으로 넘어간다.",
  [A("manual-add","할 일로 추가","today",validate=True),A("retry-ask","다시 시도","plan-input",kind="secondary")],tone="error",
  ui={"blocks":[{"type":"notice","label":"비서 응답이 늦어요. 직접 입력해 주세요."},{"type":"input","label":"할 일","field":"manualTitle","required":True}]})
scr("capture","03.06","한 줄 입력",2,"source","한 문장을 할 일 후보로 정리한다(제목, 기한, 예상 시간). 시간은 잡지 않는다.",
  [A("send-capture","정리하기","capture-proposal",validate=True),A("close-capture","닫기","today",kind="back")],
  ui={"blocks":[{"type":"input","label":"해야 할 일","field":"captureText","required":True}]})
scr("capture-proposal","03.07","한 줄 입력 · 초안",2,"source","정리한 할 일 후보를 보여 주고 적용하게 한다. 말하지 않은 기한은 비워 둔다.",
  [A("apply-capture","전부 적용","applied"),A("discard-capture","적용하지 않고 닫기","today",kind="secondary")],
  ui={"blocks":[rows(("입력","{{captureText}}"),("새 할 일","발표 자료 준비 · 금요일 마감"),("예상 시간","말하지 않아 비워 둠"))]},preview={"captureText":"금요일까지 발표 자료 준비"})
scr("reschedule","03.08","남은 일 조정",2,"source","못 끝냈거나 놓친 일을 남은 시간에 다시 배치하는 안을 만든다. 세션을 ‘더 해야 해요’로 끝낸 뒤에도 온다.",
  [A("apply-reschedule","전부 적용","applied"),A("discard-reschedule","적용하지 않고 닫기","today",kind="secondary")],
  ui={"blocks":[rows(("세션 결과","{{outcome}}"),("이어 할 시간","DB 과제 · 20:00~21:00"),("놓친 일","알고리즘 복습 · 내일 09:00~10:00"))]})

# ── 3 세션
scr("session-start","04.01","세션 시작",3,"source","제목, 분야, 연결된 할 일은 이미 채워져 있다. 공개 대상은 이어가는 일의 기본값을 따르고 그 자리에서 바꿀 수 있다.",
  [A("take-photo","사진 찍고 시작","camera"),A("start-plain","사진 없이 시작","live",kind="secondary",set={"photo":"사진 없는 기록"}),A("cancel-start","취소","today",kind="back")],
  ui={"blocks":[rows(("제목","{{sessionTitle}}"),("분야","공부·코딩"),("함께","{{together}}")),{"type":"radio","label":"공개 대상","field":"visibility","options":["나만","친구","크루"]},{"type":"select","label":"크루(공개 대상이 크루일 때)","field":"crew","options":["DB 스터디","러닝 크루"]}]},
  preview={"sessionTitle":"DB 과제","together":"혼자"},
  uxConditions=["크루를 고르면 어느 크루에 보일지 세션마다 고른다.","사진은 앱 안 카메라로만 찍는다. 앨범에서 고를 수 없다."])
scr("camera","04.02","앱 안 카메라",3,"source","앱 안 카메라로 지금 하는 일을 찍는다. 건너뛸 수 있다.",
  [A("shoot","촬영","live",set={"photo":"앱 촬영 첨부"}),A("skip-photo","건너뛰기","live",kind="secondary",set={"photo":"사진 없는 기록"}),A("back-camera","뒤로","session-start",kind="back")],
  ui={"blocks":[{"type":"visual","label":"카메라 미리보기: 책상 위 노트북과 과제","aspect":"portrait"}]})
scr("live","04.03","진행 중인 세션",3,"source","시작 시각부터 실제 시간이 흐른다. 시간을 손으로 고칠 수 없다.",
  [A("end","종료하기","session-end"),A("minimize","오늘 화면 보기","today",kind="secondary")],tone="pending",
  ui={"blocks":[rows(("제목","{{sessionTitle}}"),("시작","15:12"),("기록 방법","{{photo}}"),("공개 대상","{{visibility}}"),("함께","{{together}}"))]},
  preview={"sessionTitle":"DB 과제","photo":"앱 촬영 첨부","together":"혼자"},
  uxConditions=["앱을 닫아도 세션은 이어진다. 너무 오래 열린 세션은 서버가 정리한다."])
scr("session-end","04.04","세션 종료",3,"source","끝낼 때 하나를 고른다: 끝냈어요 / 더 해야 해요 / 오늘은 여기까지. 메모는 선택.",
  [A("finished","끝냈어요","today",set={"outcome":"끝냈어요"}),A("more","더 해야 해요","reschedule",kind="secondary",set={"outcome":"더 해야 해요"}),A("stop","오늘은 여기까지","today",kind="secondary",set={"outcome":"오늘은 여기까지"}),A("back-live","계속하기","live",kind="back")],
  ui={"blocks":[{"type":"input","label":"한 줄 메모(선택)","field":"memo"}]},
  uxConditions=["세션을 끝내도 할 일이 저절로 완료되지 않는다. ‘끝냈어요’를 골라야 완료로 바뀐다.","‘오늘은 여기까지’면 오늘은 그 일을 다시 잡지 않는다."])

# ── 4 함께
scr("together","05.01","함께",4,"source","친구의 최신 세션(진행 중이 위)과 크루의 기록을 시간순으로 본다. 시간이 많은 사람을 위로 올리지 않는다.",
  [A("join","같이 하기","session-start",set={"sessionTitle":"DB 과제","together":"가온과 함께"}),
   A("history","지난 기록","friend-history",kind="inline"),A("cheer","수고했어","together",kind="inline",inc={"cheers":1}),
   A("comment","한마디","comment",kind="inline"),A("friends","친구 관리","friends",kind="inline"),A("crew","크루","crew",kind="inline"),
   A("no-friends","친구가 아직 없음","together-empty",kind="simulation")]+tabs("together"),
  ui={"bar":"함께","blocks":[rows(("가온 · DB 과제","15:12에 시작 · 앱 촬영 첨부"),("한 줄","1번 문제 접근법 보는 중"),("수고했어","{{cheers}}번"),("한마디","{{lastComment}}"))]},
  uxConditions=["개인 제목, 계획, 비서 기록은 친구에게 보이지 않는다.","같이 하기는 상대의 기록을 바꾸지 않는다. 두 카드에 서로의 이름만 붙는다."])
scr("together-empty","05.02","함께 · 친구 없음",4,"inferred","친구가 없을 때 무엇을 할 수 있는지 보여 준다.",
  [A("add-friend","친구 찾기","friends"),A("go-today","오늘로","today",kind="secondary")],body="아직 친구가 없어요. 아이디로 친구를 찾아 보세요.")
scr("friends","05.03","친구 관리",4,"source","아이디로 찾아 요청을 보내고, 받은 요청을 수락하거나 거절한다.",
  [A("send-request","요청 보내기","friends",inc={"requests":1}),A("back-friends","함께","together",kind="back")],
  ui={"blocks":[{"type":"search","placeholder":"아이디로 찾기","field":"handle","label":"친구 찾기"},rows(("받은 요청","다온 · 수락 / 거절"),("보낸 요청","{{requests}}건"))]})
scr("comment","05.04","한마디 쓰기",4,"source","카드에 짧은 한마디를 남긴다. 세션 주인도 남의 한마디를 지울 수 없다.",
  [A("post","남기기","together",validate=True,set={"lastComment":"남김"}),A("close-comment","닫기","together",kind="close")],
  ui={"overlay":"together","blocks":[{"type":"input","label":"한마디","field":"commentText","required":True}]})
scr("friend-history","05.05","친구의 지난 기록",4,"source","카드에서 그 친구의 지난 세션을 연다. 공개된 것만 보인다.",
  [A("back-history","함께","together",kind="back")],
  ui={"blocks":[rows(("어제 20:10~21:40","알고리즘 복습 · 사진 없는 기록"),("그제 14:00~15:00","DB 과제 · 앱 촬영 첨부 · 나중에 정정함"))]})
scr("crew","05.06","크루",4,"source","학과 묶음 대신 직접 만든 크루의 기록을 본다.",
  [A("back-crew","함께","together",kind="back")],
  ui={"blocks":[rows(("DB 스터디","4명 · 오늘 3명이 기록"),("러닝 크루","6명 · 오늘 1명이 기록"))]})

# ── 5 기록
scr("record","06.01","기록",5,"source","날짜별 기록과 잔디, 분야별 세션 시간, 이어가는 일별 이력, 완료한 할 일을 본다.",
  [A("open-day","11월 23일 열기","record-day"),A("weekly","주간 돌아보기","weekly",kind="inline")]+tabs("record"),
  ui={"bar":"기록","blocks":[{"type":"visual","label":"잔디: 기록이 남은 날을 칠한 달력","aspect":"wide"},rows(("공부·코딩","이번 주 6시간 20분"),("운동","이번 주 2시간"),("완료한 할 일","7개"))]})
scr("record-day","06.02","하루 기록",5,"source","그날의 세션을 기록 방법 표시와 함께 본다.",
  [A("correct","시간 정정","correct"),A("back-day","기록","record",kind="back")],
  ui={"blocks":[rows(("15:12~16:20","DB 과제 · 앱 촬영 첨부"),("20:00~20:40","운동 · 사진 없는 기록"),("정정 표시","{{corrected}}"))]})
scr("correct","06.03","나중에 정정",5,"source","끝난 세션의 시간을 고치면 ‘나중에 정정함’이 붙고, 친구에게도 그대로 보인다.",
  [A("save-correct","정정 저장","record-day",set={"corrected":"나중에 정정함"}),A("back-correct","취소","record-day",kind="back")],
  ui={"blocks":[{"type":"select","label":"끝난 시각","field":"endTime","options":["16:20","16:00","15:50"]},{"type":"notice","label":"정정하면 ‘나중에 정정함’이 기록에 남아요."}]})
scr("weekly","06.04","주간 돌아보기",5,"source","기록에 근거한 요약만 보여 준다(P1).",
  [A("back-weekly","기록","record",kind="back")],
  ui={"blocks":[rows(("세션","9번 · 8시간 20분"),("가장 길게 한 일","DB 과제"),("예상보다 오래 걸린 분야","과제 · 평소 1.4배"))]})

req=lambda id,group,screen,title,expected,action=None,origin="source": {k:v for k,v in dict(id=id,group=group,screen=screen,title=title,expected=expected,action=action,origin=origin).items() if v is not None}
R=[
 req("school-mail","가입","email","학교 메일로만 가입","고려대 메일이 아니면 가입할 수 없고 다시 입력하게 한다.","wrong-domain"),
 req("draft-only","비서","proposal","적용 전에는 저장하지 않음","초안을 닫으면 아무것도 저장되지 않고 오늘로 돌아간다.","discard"),
 req("ask-estimate","비서","proposal","예상 시간이 없으면 30분으로 잡고 묻기","답하면 그 길이로 바뀐다.","est-60"),
 req("ask-skip","비서","proposal","건너뛰면 30분","건너뛰기를 누르면 30분으로 둔다.","est-skip"),
 req("ask-timeout","비서","proposal","2분 동안 답이 없으면 30분","답이 없으면 30분으로 둔다.","est-timeout"),
 req("fit-check","비서","proposal","다 들어가지 않는 일은 가용 시간 점검","가용 시간을 보여 주고 일부만·다른 날·건너뛰기 중 고르게 한다.","fit-partial"),
 req("fallback","비서","plan-input","비서 실패 시 직접 입력","실패하면 직접 입력으로 넘어가 할 일을 추가할 수 있다.","fail"),
 req("photo-optional","세션","session-start","사진은 선택","사진 없이 시작할 수 있고 ‘사진 없는 기록’으로 표시된다.","start-plain"),
 req("in-app-camera","세션","camera","앱 안 촬영","촬영하면 ‘앱 촬영 첨부’로 표시된다.","shoot"),
 req("end-outcome","세션","session-end","종료할 때 결과 고르기","‘더 해야 해요’면 비서가 이어 할 시간을 제안한다.","more"),
 req("join","함께","together","같이 하기","누르면 내 세션 시작으로 이어지고 ‘가온과 함께’로 표시된다.","join"),
 req("correct-label","기록","correct","정정 표시","시간을 고치면 ‘나중에 정정함’이 남는다.","save-correct"),
 req("empty-feed","함께","together-empty","친구가 없을 때","친구 찾기로 갈 수 있다.","add-friend","inferred"),
]
step=lambda action,screen=None,**k: {k2:v for k2,v in dict(action=action,screen=screen,**k).items() if v is not None}
SC=[
 {"id":"signup","title":"가입 · 학교 메일부터 오늘까지","start":"email","steps":[
   step("send-code","code",hint="학교 메일을 입력하세요."),step("verify","profile",hint="6자리 코드를 입력하세요."),step("save-profile","calendar",hint="이름을 입력하세요."),step("allow-cal","today",vars={"calendar":"연결됨"})]},
 {"id":"plan-answer","title":"하루 정리 · 예상 시간 답하고 일부만 잡기","start":"today","steps":[
   step("plan-day","consent"),step("agree","plan-input"),step("ask","proposal",vars={"ask":"묻는 중","est":"30분"}),
   step("est-60","proposal",vars={"est":"60분","ask":"답함"}),step("fit-partial","proposal",vars={"fit":"오늘 1시간 30분만"}),step("apply","applied"),step("done-applied","today")]},
 {"id":"plan-timeout","title":"하루 정리 · 2분 동안 답 없음, 내일로 옮기기","start":"plan-input","steps":[
   step("ask","proposal"),step("est-timeout","proposal",vars={"est":"30분","ask":"시간 지남"}),step("fit-later","proposal",vars={"fit":"내일 08:00로 옮김"}),step("apply","applied")]},
 {"id":"plan-fail","title":"비서 실패 · 직접 입력","start":"plan-input","steps":[
   step("fail","assistant-failed"),step("manual-add","today",hint="할 일 제목을 입력하세요.")]},
 {"id":"session","title":"세션 · 사진 찍고 시작해서 더 해야 해요","start":"today","steps":[
   step("start-now","session-start"),step("take-photo","camera"),step("shoot","live",vars={"photo":"앱 촬영 첨부"}),step("end","session-end"),
   step("more","reschedule",vars={"outcome":"더 해야 해요"}),step("apply-reschedule","applied")]},
 {"id":"join","title":"함께 · 같이 하기","start":"together","steps":[
   step("join","session-start",vars={"together":"가온과 함께"}),step("start-plain","live",vars={"photo":"사진 없는 기록"}),step("end","session-end"),step("finished","today",vars={"outcome":"끝냈어요"})]},
 {"id":"correct","title":"기록 · 나중에 정정","start":"record","steps":[
   step("open-day","record-day"),step("correct","correct"),step("save-correct","record-day",vars={"corrected":"나중에 정정함"})]},
]
J=lambda title,start,steps: {"title":title,"start":start,"steps":steps}
audit={"journeys":[
  J("예상 시간 답하기","plan-input",[step("ask","proposal"),step("est-60","proposal",vars={"est":"60분"},requirement="ask-estimate"),step("fit-partial","proposal",vars={"fit":"오늘 1시간 30분만"},requirement="fit-check"),step("apply","applied")]),
  J("사진 찍고 시작","today",[step("start-now","session-start"),step("take-photo","camera"),step("shoot","live",vars={"photo":"앱 촬영 첨부"},requirement="in-app-camera"),step("end","session-end"),step("more","reschedule",requirement="end-outcome")]),
  J("같이 하기","together",[step("join","session-start",vars={"together":"가온과 함께"},requirement="join"),step("start-plain","live",vars={"photo":"사진 없는 기록"},requirement="photo-optional")]),
  J("정정 표시","record",[step("open-day","record-day"),step("correct","correct"),step("save-correct","record-day",vars={"corrected":"나중에 정정함"},requirement="correct-label")]),
 ],"recovery":[
  J("학교 메일이 아님 → 다시 입력","email",[step("wrong-domain","email-error",requirement="school-mail"),step("retry-email","email",requirement="school-mail")]),
  J("건너뛰면 30분","plan-input",[step("ask","proposal"),step("est-skip","proposal",vars={"est":"30분","ask":"건너뜀"},requirement="ask-skip")]),
  J("2분 동안 답 없음","plan-input",[step("ask","proposal"),step("est-timeout","proposal",vars={"est":"30분","ask":"시간 지남"},requirement="ask-timeout")]),
  J("초안을 적용하지 않고 닫기","plan-input",[step("ask","proposal"),step("discard","today",requirement="draft-only")]),
  J("비서 실패 → 직접 입력","plan-input",[step("fail","assistant-failed",requirement="fallback"),{"field":"manualTitle","type":"input","value":"DB 과제 1번"},step("manual-add","today",requirement="fallback")]),
  J("친구 없음 → 친구 찾기","together",[step("no-friends","together-empty"),step("add-friend","friends",requirement="empty-feed")]),
  J("카메라에서 뒤로","session-start",[step("take-photo","camera"),step("back-camera","session-start")]),
 ]}
flow={"id":"pondu-app","title":"Pondu","goal":"오늘 할 일을 정리하고, 실제로 한 시간을 세션으로 남겨 친구와 나눈다.","device":"mobile",
 "start":"email","entries":["today","together","record","plan-input","session-start"],
 "source":"docs/PRD.md v0.4, docs/specs/CONTRACT-ADDENDUM.md 보정 3, ios/PonduKit 화면 구현",
 "stages":["가입","오늘","비서","세션","함께","기록"],
 "vars":{"email":"","otp":"","resent":0,"name":"","major":"인공지능학과","calendar":"연결 안 됨","consented":False,
   "planText":"","ask":"묻는 중","est":"30분","fit":"미정","manualTitle":"","captureText":"","pasted":"",
   "sessionTitle":"DB 과제","together":"혼자","visibility":"친구","crew":"DB 스터디","photo":"사진 없는 기록","memo":"","outcome":"없음",
   "cheers":0,"lastComment":"없음","commentText":"","handle":"","requests":0,"corrected":"없음","endTime":"16:20"},
 "screens":S,"scenarios":SC,
 "decisions":[
  {"screen":"session-start","question":"공개 대상이 크루일 때 고른 크루에게만 보일지, 고른 크루와 내 친구 모두에게 보일지 정해야 합니다(지금 서버는 크루+친구)."},
  {"screen":"proposal","question":"예상 시간 질문에 알림에서 바로 답하게 할지 정해야 합니다(지금은 알림으로 알리기만 하고 앱에서 답함)."},
  {"screen":"proposal","question":"건너뛰거나 답이 없을 때 할 일의 예상 시간에도 30분을 저장할지 정해야 합니다(지금은 블록만 30분, 예상 시간은 비워 둠)."},
  {"screen":"code","question":"코드가 틀렸을 때와 만료됐을 때의 문구, 다시 받기 간격을 정해야 합니다."},
  {"screen":"together-empty","question":"친구가 없을 때 초대 링크를 줄지 정해야 합니다."}],
 "review":{"locale":"ko","artboard":{"width":390,"height":844},"groupDirection":"vertical","requirements":R,"audit":audit}}
json.dump(flow,open("design/pondu.flow.json","w"),ensure_ascii=False,indent=1)
print(len(S),"screens")
