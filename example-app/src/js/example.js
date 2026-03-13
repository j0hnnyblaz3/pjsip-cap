import { Pjsip } from 'capacitor-pjsip';

window.testEcho = () => {
    const inputValue = document.getElementById("echoInput").value;
    Pjsip.echo({ value: inputValue })
}
